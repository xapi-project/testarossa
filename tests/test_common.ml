open Yorick
open Lwt
open Xen_api
open Xen_api_lwt_unix

let uri ip = Printf.sprintf "http://%s" ip
let username = ref "root"
let password = ref "xenroot"

let meg = Int64.mul 1024L 1024L
let meg32 = Int64.mul meg 32L

type host_state =
  | Slave of bytes
  | Master

type host = {
  name : bytes;
  ip : bytes;
  uuid : bytes;
}

type storage_server = {
  storage_ip : bytes;
  iscsi_iqn : bytes;
}

type state = {
  hosts : host list;
  pool : [`Pool] API.Ref.t; (* reference *)
  master : [`Host] API.Ref.t; (* reference *)
  master_uuid : bytes; (* uuid *)
  master_rpc : (Rpc.call -> Rpc.response Lwt.t);
  master_session : [`Session] API.Ref.t;
  pool_setup : bool;
  iscsi_sr : ([`SR] API.Ref.t * bytes) option; (* reference * uuid *)
  nfs_sr : ([`SR] API.Ref.t * bytes) option; (* reference * uuid *)
  gfs2_sr : ([`SR] API.Ref.t * bytes) option; (* reference * uuid *)
  mirage_vm : [`VM] API.Ref.t option; (* reference *)
}

type sr_type = NFS | ISCSI | GFS2

let update_box name =
  ?| (Printf.sprintf "vagrant box update %s" name)

(* TODO: if too many run them in groups, like XC *)
let start_all prefix m =
  let hosts = Array.init m (fun i -> i+1) |> Array.to_list |> List.map (Printf.sprintf "%s%d" prefix) in
  let hosts = String.concat " " hosts in
  ?| (Printf.sprintf "vagrant up %s infrastructure --parallel --provider=xenserver" hosts)
    
let initialize_all prefix m =
  let hosts = Array.init m (fun i -> i+1) |> Array.to_list |> List.map (Printf.sprintf "%s%d" prefix) in
  let hosts = String.concat " " hosts in
  (* assuming we only have ansible and shell provisioners *)
  ?| (Printf.sprintf "vagrant up %s infrastructure --parallel --provider=xenserver --provision-with=shell" hosts);
  (* ansible requires all hosts to be up already *)
  ?| (Printf.sprintf "vagrant up %s infrastructure --provision-with=ansible" hosts)

let destroy_all prefix m =
  let hosts = Array.init m (fun i -> i+1) |> Array.to_list |> List.map (Printf.sprintf "%s%d" prefix) in
  ?| (Printf.sprintf "vagrant destroy %s infrastructure" (String.concat " " hosts))
    
let provision_all prefix m =
  let hosts = Array.init m (fun i -> i+1) |> Array.to_list |> List.map (Printf.sprintf "%s%d" prefix) in
  ?| (Printf.sprintf "vagrant provision %s" (String.concat " " hosts))

let setup_infra () =
  let wwn = ?|> "vagrant ssh infrastructure -c \"/scripts/get_wwn.py\"" |> trim in
  let ip = ?|> "vagrant ssh infrastructure -c \"/scripts/get_ip.sh\"" |> trim in
  {iscsi_iqn=wwn; storage_ip=ip}

let run_script ~host ~script =
  echo "Running %S on %s" script host;
  ?|> "vagrant ssh %s -c \"sudo /scripts/%s\"" host script |> trim

let get_ip host =
  ?|> "vagrant ssh %s -c \"/scripts/get_eth1_ip.sh\"" host |> trim

let setup_cluster_one ~host =
  let ip = get_ip host in
  ?|> "vagrant ssh %s -c \"xcli create '{\\\"hostname\\\":\\\"%s\\\",\\\"addresses\\\":[\\\"%s\\\"]}'\"" host host ip |> trim

let get_iscsi_device ~host =
  let iscsi_ip = "169.254.0.16" in (* TODO *)
  ?|> "vagrant ssh %s -c \"/usr/bin/ls --color=none -1 /dev/disk/by-path/ip-%s:3260-*-0\"" host iscsi_ip |> trim

let mkfs_gfs2 ~host ~device =
  let cluster_name = "xapi-cluster" in
  let fs_name = "gfs" in
  let num_journals = 4 in (* TODO 16? *)
  ?|> "vagrant ssh %s -c \"/usr/sbin/mkfs.gfs2 -O -t %s:%s -p lock_dlm -j %d %s\"" host cluster_name fs_name num_journals device |> trim

let mount_gfs2 ~host ~device =
  let mountpoint = "/mnt" in
  ?|> "vagrant ssh %s -c \"/usr/bin/mount -t gfs2 -o noatime,nodiratime %s %s\"" host device mountpoint |> trim

let get_hosts prefix m =
  let get_host n =
    match
      ?|> "vagrant ssh %s%d -c \"/scripts/xs/get_public_ip.sh\"" prefix n |> trim |> Stringext.split ~on:','
    with
    | [uuid; ip] -> {name=(Printf.sprintf "%s%d" prefix n); ip; uuid}
    | _ -> failwith "Failed to get host's uuid and IP"
  in
  List.map get_host (Array.init m (fun i -> i+1) |> Array.to_list)

let lwt_read file = Lwt_io.lines_of_file file |> Lwt_stream.to_list
let get_ref name =
  lwt_read (Printf.sprintf ".vagrant/machines/%s/xenserver/id" name)
  >|= List.hd >|= API.Ref.of_string

let get_vm_ref prefix i =
  get_ref (Printf.sprintf "%s%d" prefix i)

type snapshot_config = {
  machine: string;
  cluster_max: int;
  prefix: string;
}

let name_of_config conf name m =
  Printf.sprintf "testarossa/%s/%d/%d/%s/%s" conf.machine m conf.cluster_max conf.prefix name

let vagrant_shutdown name =
  ?| (Printf.sprintf "vagrant ssh %s -c \"sudo shutdown -P now\"" name)

let vagrant_sync name =
  ?| (Printf.sprintf "vagrant ssh %s -c \"sync\"" name)

let snapshot_all conf ?(consistent=false) m ~new_name =
  let new_name = name_of_config conf new_name m in
  let rpc = make (uri conf.machine) in
  Session.login_with_password rpc !username !password "1.0" "testarossa" >>=
  fun session_id ->
  let snapshot_host name =
    get_ref name >>= fun vm ->
    begin if consistent then
      Lwt_preemptive.detach vagrant_sync name
    else Lwt.return_unit
    end >>= fun () ->
    VM.snapshot ~rpc ~session_id ~vm ~new_name >>= fun id ->
    Lwt.return id
  in
  "infrastructure" ::
  (Array.init m (fun i -> Printf.sprintf "%s%d" conf.prefix (i+1)) |> Array.to_list) |>
  Lwt_list.map_p snapshot_host

let revert_all conf m ~snapshot_name =
  let rpc = make (uri conf.machine) in
  let expected_name = name_of_config conf snapshot_name m in
  Session.login_with_password rpc !username !password "1.0" "testarossa" >>=
  fun session_id ->

  let is_ours snapshot =
    VM.get_name_label ~rpc ~session_id ~self:snapshot >|= fun name ->
    name = expected_name
  in

  let revert_host name =
    get_ref name >>= fun vm ->
    echo "Getting list of snapshot for VM %s" (API.Ref.string_of vm);
    VM.get_snapshots ~rpc ~session_id ~self:vm >>= fun snapshots ->
    Lwt_list.filter_p is_ours snapshots >>= fun snapshots ->
    let snapshot = List.hd snapshots in
    echo "Reverting VM %s to clean snapshot %s" (API.Ref.string_of vm) (API.Ref.string_of snapshot);
    VM.revert ~rpc ~session_id ~snapshot
  in
  "infrastructure" ::
  (Array.init m (fun i -> Printf.sprintf "%s%d" conf.prefix (i+1)) |> Array.to_list) |>
  Lwt_list.iter_p revert_host


let get_state hosts =
  let get_host_state host =
    let rpc = make (uri host.ip) in
    Lwt.catch
      (fun () ->
         Printf.printf "Checking host %s (ip=%s)..." host.name host.ip;
         Session.login_with_password rpc "root" "xenroot" "1.0" "testarossa" >>=
         fun _ ->
         Printf.printf "master\n%!";
         Lwt.return (host,Master))
      (fun e ->
         match e with
         | Api_errors.Server_error("HOST_IS_SLAVE",[master]) ->
           Printf.printf "slave\n%!";
           Lwt.return (host, Slave master)
         | e -> fail e)
  in Lwt_list.map_s get_host_state hosts


let setup_pool hosts =
  Printf.printf "Pool is not set up: Making it\n%!";
  Lwt_list.map_p (fun host ->
      let rpc = make (uri host.ip) in
      Session.login_with_password rpc "root" "xenroot" "1.0" "testarossa"
      >>= fun sess ->
      Lwt.return (rpc,sess)) hosts
  >>= fun rss ->
  let slaves = List.tl rss in
  Lwt_list.iter_s (fun (rpc,session_id) ->
      Pool.join ~rpc ~session_id ~master_address:(List.hd hosts).ip
        ~master_username:"root" ~master_password:"xenroot" >>= fun () ->
      Lwt_unix.sleep 30.) slaves >>= fun () ->
  Printf.printf "All slaves told to join: waiting for all to be enabled\n%!";
  let rpc,session_id = List.hd rss in
  let rec wait () =
    Host.get_all_records ~rpc ~session_id >>= fun hrefrec ->
    if List.exists (fun (_,r) -> not r.API.host_enabled) hrefrec
    then (Lwt_unix.sleep 1.0 >>= fun () -> wait ())
    else return ()
  in wait ()
  >>= fun () ->
  Printf.printf "Everything enabled. Sleeping 10 seconds to prevent a race\n%!";
  (* Nb. the following sleep is to prevent a race between SR.create and
     thread_zero plugging all PBDs *)
  Lwt_unix.sleep 30.0 >>= fun () ->
  Pool.get_all ~rpc ~session_id >>=
  fun pools ->
  let pool = List.hd pools in
  Pool.get_master ~rpc ~session_id ~self:pool >>=
  fun master_ref ->
  Host.get_uuid ~rpc ~session_id ~self:master_ref >>=
  fun master_uuid ->
  Lwt.return {
    hosts = hosts;
    pool = pool;
    master = master_ref;
    master_uuid = master_uuid;
    master_rpc = rpc;
    master_session = session_id;
    pool_setup = true;
    iscsi_sr = None;
    nfs_sr = None;
    gfs2_sr = None;
    mirage_vm = None;
  }


let get_pool hosts =
  get_state hosts >>= fun host_states ->
  if List.filter (fun (_,s) -> s=Master) host_states |> List.length = 1
  then begin
    let master = fst (List.find (fun (_,s) -> s=Master) host_states) in
    let rpc = make (uri master.ip) in
    Session.login_with_password rpc "root" "xenroot" "1.0" "testarossa"
    >>= fun session_id ->
    Pool.get_all ~rpc ~session_id >>=
    fun pools ->
    let pool = List.hd pools in
    Pool.get_master ~rpc ~session_id ~self:pool >>=
    fun master_ref ->
    Host.get_uuid ~rpc ~session_id ~self:master_ref >>=
    fun master_uuid ->    
    Lwt.return {
      hosts = hosts;
      pool = pool;
      master = master_ref;
      master_uuid = master_uuid;
      master_rpc = rpc;
      master_session = session_id;
      pool_setup = true;
      iscsi_sr = None;
      nfs_sr = None;
      gfs2_sr = None;
      mirage_vm = None;
    }
  end else begin
    setup_pool hosts
  end


let create_iscsi_sr state =
  Printf.printf "Creating an ISCSI SR\n%!";
  let rpc = state.master_rpc in
  let storage = setup_infra () in
  let session_id = state.master_session in
  Lwt.catch
    (fun () -> 
       SR.probe ~rpc ~session_id ~host:state.master
                ~device_config:["target", storage.storage_ip; "targetIQN", storage.iscsi_iqn]
                ~_type:"lvmoiscsi" ~sm_config:[])
    (fun e -> match e with
       | Api_errors.Server_error (_,[_;_;xml]) -> Lwt.return xml
       | e -> Printf.printf "Got another error: %s\n" (Printexc.to_string e);
         Lwt.return "<bad>")
  >>= fun xml ->
  let open Ezxmlm in
  let (_,xmlm) = from_string xml in
  let scsiid = xmlm |> member "iscsi-target" |> member "LUN" |> member "SCSIid"
         |> data_to_string in
  Printf.printf "SR Probed: SCSIid=%s\n%!" scsiid;
  SR.create ~rpc ~session_id ~host:state.master
    ~device_config:["provider", "iscsi"; "ips", storage.storage_ip; "iqns", storage.iscsi_iqn; "SCSIid", scsiid]
    ~_type:"lvmoiscsi" ~physical_size:0L ~name_label:"iscsi-sr"
    ~name_description:"" ~content_type:""
    ~sm_config:[] ~shared:true >>= fun ref ->
  SR.get_uuid ~rpc ~session_id ~self:ref >>= fun uuid ->
  return (ref, uuid)

let device_config ?(provider="iscsi") ~ips ~iqns ?scsiid () =
  let open Ezjsonm in
  let conf = [ "provider", `String provider;
    "ips", `String ips;
    "iqns", `String iqns;
  ] in
  (match scsiid with
  | Some id -> ("ScsiId", `String id) :: conf
  | None -> conf) |> dict |> to_string ~minify:true |> fun x -> ["uri", x]

let get_management_pifs ~rpc ~session_id =
  echo "Getting all PIFs\n%!";
  (* get_all_records raises Not_found, probably due to version mismatch between
   * xen-api-client and xapi having different fields... *)
  PIF.get_all ~rpc ~session_id
  >>= Lwt_list.filter_p (fun self -> PIF.get_management ~rpc ~session_id ~self)

let create_gfs2_sr state =
  Printf.printf "Creating GFS2 SR\n%!";
  let rpc = state.master_rpc in
  let storage = setup_infra () in
  Printf.printf "got storage\n%!";
  let session_id = state.master_session in

  (* probe as if it was an iSCSI SR, since we don't have probe for GFS2 yet *)
  Lwt.catch
    (fun () -> 
       SR.probe ~rpc ~session_id ~host:state.master
                ~device_config:["target", storage.storage_ip; "targetIQN", storage.iscsi_iqn]
                ~_type:"lvmoiscsi" ~sm_config:[])
    (fun e -> match e with
       | Api_errors.Server_error (_,[_;_;xml]) -> Lwt.return xml
       | e -> Printf.printf "Got another error: %s\n" (Printexc.to_string e);
         Lwt.return "<bad>")
  >>= fun xml ->
  let open Ezxmlm in
  echo "got: %s" xml;
  let (_,xmlm) = from_string xml in
  let scsiid = xmlm |> member "iscsi-target" |> member "LUN" |> member "SCSIid"
         |> data_to_string in
  Printf.printf "SR Probed: SCSIid=%s\n%!" scsiid;
  (*  let scsiid = "3600140519bb4ca7f29c43b59bc09acb3" in*)
(*  let scsiid = "36001405e177b3f19b5946e88d96d6d86" in *)


(*  Lwt.catch
    (fun () ->
       SR.probe ~rpc ~session_id ~host:state.master
         ~device_config:(device_config ~ips:storage.storage_ip ~iqns:storage.iscsi_iqn ())
         ~_type:"gfs2" ~sm_config:[])
    (fun e -> match e with
       | Api_errors.Server_error (_,[_;_;xml]) -> Lwt.return xml
       | e -> Printf.printf "Got another error: %s\n" (Printexc.to_string e);
         Lwt.return "<bad>")
  >>= fun xml ->
  let open Ezxmlm in
  Printf.printf "Got: %s\n%!" xml;
  let (_,xmlm) = from_string xml in
  let scsiid = xmlm |> member "iscsi-target" |> member "LUN" |> member "SCSIid"
       |> data_to_string in
  Printf.printf "SR Probed: SCSIid=%s\n%!" scsiid;*)
  Pool.get_uuid ~rpc ~session_id ~self:state.pool >>= fun pool_uuid ->

  get_management_pifs ~rpc ~session_id >>= function
  | [] -> Lwt.fail_with "No management interface found"
  | (pif :: _) as pifs ->

  echo "Setting disallow-unplug";
  Lwt_list.iter_p (fun self ->
    PIF.set_disallow_unplug ~rpc ~session_id ~self ~value:true) pifs
  >>= fun () ->

  PIF.get_network ~rpc ~session_id ~self:pif >>= fun network ->
  Network.get_uuid ~rpc ~session_id ~self:network >>= fun network_uuid ->
  let master = List.find (fun host -> host.uuid = state.master_uuid) state.hosts
  in

  echo "Creating cluster";

  let cluster =
(*    match (?|>) "xe cluster-list -s %s -u %s -pw %s --minimal" master.ip !username !password with
    | "" ->*)

        ?|> "xe cluster-pool-create -s %s -u %s -pw %s pool-uuid=%s network-uuid=%s"
      master.ip !username !password pool_uuid network_uuid

(*    | c -> c *)
  in
  echo "Creating SR";
  SR.create ~rpc ~session_id ~host:state.master
    ~device_config:(device_config ~ips:storage.storage_ip ~iqns:storage.iscsi_iqn ~scsiid ())
    ~_type:"gfs2" ~physical_size:0L ~name_label:"gfs2-sr"
    ~name_description:"" ~content_type:""
    ~sm_config:[] ~shared:true >>= fun ref ->
  SR.get_uuid ~rpc ~session_id ~self:ref >>= fun uuid ->
  return (ref, uuid)


let create_nfs_sr state =
  Printf.printf "Creating an NFS SR\n%!";
  let rpc = state.master_rpc in
  let storage = setup_infra () in
  Printf.printf "server: '%s' serverpath: '/nfs'\n%!" storage.storage_ip;
  let session_id = state.master_session in
  SR.create ~rpc ~session_id ~host:state.master
    ~device_config:["server", storage.storage_ip; "serverpath", "/nfs"]
    ~_type:"nfs-ng" ~physical_size:0L ~name_label:"nfs-sr"
    ~name_description:"" ~content_type:""
    ~sm_config:[] ~shared:true >>= fun ref ->
  SR.get_uuid ~rpc ~session_id ~self:ref >>= fun uuid ->
  return (ref, uuid)


let find_or_create_sr state ty =
  let rpc,session_id = state.master_rpc,state.master_session in
  let srty_of_ty = function
    | ISCSI -> "lvmoiscsi"
    | NFS -> "nfs-ng"
    | GFS2 -> "gfs2"
  in
(*  Printf.printf "get_all_records0\n%!";
  SR.get_all_records ~rpc ~session_id >>= fun sr_ref_recs ->
  Printf.printf "get_all_records1\n%!";
  let pred = fun (sr_ref, sr_rec) -> sr_rec.API.sR_type = (srty_of_ty ty) in
  if List.exists pred sr_ref_recs
  then begin
    Printf.printf "found\n%!";
    let (rf, rc) = List.find pred sr_ref_recs in
    Lwt.return (rf, rc.API.sR_uuid)
  end else*) begin
    match ty with
    | ISCSI -> create_iscsi_sr state
    | NFS -> create_nfs_sr state
    | GFS2 -> create_gfs2_sr state
  end


let get_sr state ty =
  match (ty, state.iscsi_sr, state.nfs_sr) with
  | _, Some _, _ -> Lwt.return state
  | ISCSI, _, _ -> find_or_create_sr state ty >>= fun s -> Lwt.return { state with iscsi_sr = Some s }
  | NFS, _, _ -> find_or_create_sr state ty >>= fun s -> Lwt.return { state with nfs_sr = Some s }
  | GFS2, _, _ -> find_or_create_sr state ty  >>= fun s -> Lwt.return { state with gfs2_sr = Some s }



let find_template rpc session_id name =
  VM.get_all_records rpc session_id >>= fun vms ->
  let filtered = List.filter (fun (_, record) ->
      (name = record.API.vM_name_label) &&
      record.API.vM_is_a_template)
      vms in
  match filtered with
  | [] -> Lwt.return None
  | (x,_) :: _ -> Lwt.return (Some x)


let create_mirage_vm state =
  let rpc = state.master_rpc in
  let session_id = state.master_session in
  find_template rpc session_id "Other install media" >>= fun template_opt ->
  let template = 
    match template_opt with
    | Some vm -> vm
    | None -> 
      Printf.fprintf stderr "Failed to find suitable template";
      failwith "No template"
  in
  VM.clone rpc session_id template "mirage" >>= fun vm ->
  VM.provision rpc session_id vm >>= fun _ ->
  VM.set_PV_kernel rpc session_id vm "/boot/guest/test-vm.xen.gz" >>= fun () ->
  VM.set_HVM_boot_policy rpc session_id vm "" >>= fun () ->
  VM.set_memory_limits ~rpc ~session_id ~self:vm ~static_min:meg32 ~static_max:meg32 ~dynamic_min:meg32 ~dynamic_max:meg32 >>= fun () ->
  Lwt.return ({state with mirage_vm = Some vm}, vm)

let find_or_create_mirage_vm state =
  let rpc = state.master_rpc in
  let session_id = state.master_session in
  VM.get_all_records_where ~rpc ~session_id ~expr:"field \"name__label\"=\"mirage\""
  >>= function
  | vmrefrec::_ ->
    let vm = fst vmrefrec in
    Lwt.return ({state with mirage_vm = Some vm}, vm)
  | [] ->
    create_mirage_vm state

let get_control_domain state host =
  let rpc = state.master_rpc in
  let session_id = state.master_session in
  Printf.printf "About to get all records...\n%!";
  VM.get_all_records ~rpc ~session_id
  >>= fun vms ->
  Printf.printf "Finding control domain\n%!";
  List.find
    (fun (vm_ref, vm_rec) ->
       vm_rec.API.vM_resident_on=host && vm_rec.API.vM_is_control_domain)
    vms |> fst |> Lwt.return

let run_and_self_destruct (t : 'a Lwt.t) : 'a =
  let t' =
    Lwt.finalize (fun () -> t) (fun () ->
      Printexc.print_backtrace stderr;
      let name = Sys.argv.(0) in
      let ocamlscript_exe =
        if Filename.check_suffix name "exe" then name else name ^ ".exe" in
      if (try Unix.(access ocamlscript_exe [ F_OK ]); true with _ -> false)
      then
        Lwt_io.printlf "Unlinking ocamlscript compilation: %s" ocamlscript_exe
        >>= fun () ->
        Lwt_unix.unlink ocamlscript_exe
      else return ()
    )
  in
  Lwt_main.run t'

let kill_children_at_exit () =
  at_exit (fun () ->
      let term = 15 in
      Unix.kill 0 term)
