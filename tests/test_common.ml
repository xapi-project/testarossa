open Yorick
open Xen_api
open Xen_api_lwt_unix

let printf  = Printf.printf
let sprintf = Printf.sprintf
let fprintf = Printf.fprintf

let uri ip = sprintf "http://%s" ip
let username = ref "root"
let password = ref "xenroot"


let meg n = Int64.(mul 1024L @@ mul 1024L @@ of_int n)
let meg32 = meg 32

type host_state =
  | Slave of string
  | Master

type host = {
  name : string;
  ip : string;
  uuid : string;
}

type storage_server = {
  storage_ip : string;
  iscsi_iqn : string;
}

type state = {
  hosts : host list;
  pool : string; (* reference *)
  master : string; (* reference *)
  master_uuid : string; (* uuid *)
  master_rpc : (Rpc.call -> Rpc.response Lwt.t);
  master_session : string;
  pool_setup : bool;
  iscsi_sr : (string * string) option; (* reference * uuid *)
  nfs_sr : (string * string) option; (* reference * uuid *)
  mirage_vm : string option; (* reference *)
}

type sr_type = NFS | ISCSI


(** [seq n] return a list of length [n] with members 1 .. n *)
let rec seq n = 
  let rec loop lst = function
  | 0 -> lst
  | n -> loop (n::lst) (n-1)
  in 
    loop [] n

(** [fail msg] makes a thread fail *) 
let fail msg = Lwt.fail (Failure msg) 

let update_box name =
  ?| (sprintf "vagrant box update %s" name)

let start_all m =
  let hosts = seq m |> List.map (sprintf "host%d") |> String.concat " " in
    ?| (sprintf "vagrant up %s infrastructure --parallel --provider=xenserver" hosts)


let setup_infra () =
  let wwn = 
    ?|> "vagrant ssh infrastructure -c \"/scripts/get_wwn.py\"" 
    |> trim in
  let ip = 
    ?|> "vagrant ssh infrastructure -c \"/scripts/get_ip.sh\"" 
    |> trim 
  in
    {iscsi_iqn=wwn; storage_ip=ip}


let get_hosts m =
  let get_host n =
    match
      ?|> "vagrant ssh host%d -c \"/scripts/get_public_ip.sh\"" n |> trim |> Stringext.split ~on:','
    with
    | [uuid; ip] -> {name=(sprintf "host%d" n); ip; uuid}
    | _ -> failwith "Failed to get host's uuid and IP"
  in
    List.map get_host (seq m)


let get_state hosts =
  let get_host_state host =
    let rpc = make (uri host.ip) in
    Lwt.catch
      (fun () ->
         printf "Checking host %s (ip=%s)..." host.name host.ip;
         Session.login_with_password rpc !username !password "1.0" "testarossa" >>=
         fun _ ->
         printf "master\n%!";
         Lwt.return (host,Master))
      (fun e ->
         match e with
         | Api_errors.Server_error("HOST_IS_SLAVE",[master]) ->
           printf "slave\n%!";
           Lwt.return (host, Slave master)
         | e -> Lwt.fail e)
  in Lwt_list.map_s get_host_state hosts


let setup_pool hosts =
  printf "Pool is not set up: Making it\n%!";
  Lwt_list.map_p (fun host ->
      let rpc = make (uri host.ip) in
      Session.login_with_password rpc !username !password "1.0" "testarossa"
      >>= fun sess ->
      Lwt.return (rpc,sess)) hosts
  >>= fun rss ->
  let slaves = List.tl rss in
  Lwt_list.iter_p (fun (rpc,session_id) ->
      Pool.join ~rpc ~session_id ~master_address:(List.hd hosts).ip
        ~master_username:!username ~master_password:!password) slaves >>= fun () ->
  printf "All slaves told to join: waiting for all to be enabled\n%!";
  let rpc,session_id = List.hd rss in
  let rec wait () =
    Host.get_all_records ~rpc ~session_id >>= fun hrefrec ->
    if List.exists (fun (_,r) -> not r.API.host_enabled) hrefrec
    then (Lwt_unix.sleep 1.0 >>= fun () -> wait ())
    else return ()
  in wait ()
  >>= fun () ->
  printf "Everything enabled. Sleeping 10 seconds to prevent a race\n%!";
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
    mirage_vm = None;
  }


let get_pool hosts =
  get_state hosts >>= fun host_states ->
  if List.filter (fun (_,s) -> s=Master) host_states |> List.length = 1
  then begin
    let master = fst (List.find (fun (_,s) -> s=Master) host_states) in
    let rpc = make (uri master.ip) in
    Session.login_with_password rpc !username !password "1.0" "testarossa"
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
      mirage_vm = None;
    }
  end else begin
    setup_pool hosts
  end


let create_iscsi_sr state =
  printf "Creating an ISCSI SR\n%!";
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
       | e -> printf "Got another error: %s\n" (Printexc.to_string e);
         Lwt.return "<bad>")
  >>= fun xml ->
  let open Ezxmlm in
  let (_,xmlm) = from_string xml in
  let scsiid = xmlm |> member "iscsi-target" |> member "LUN" |> member "SCSIid" |> data_to_string in
  printf "SR Probed: SCSIid=%s\n%!" scsiid;
  SR.create ~rpc ~session_id ~host:state.master
    ~device_config:["target", storage.storage_ip; "targetIQN", storage.iscsi_iqn; "SCSIid", scsiid]
    ~_type:"lvmoiscsi" ~physical_size:0L ~name_label:"iscsi-sr"
    ~name_description:"" ~content_type:""
    ~sm_config:[] ~shared:true >>= fun ref ->
  SR.get_uuid ~rpc ~session_id ~self:ref >>= fun uuid ->
  return (ref, uuid)


let create_nfs_sr state =
  printf "Creating an NFS SR\n%!";
  let rpc = state.master_rpc in
  let storage = setup_infra () in
  printf "server: '%s' serverpath: '/nfs'\n%!" storage.storage_ip;
  let session_id = state.master_session in
  SR.create ~rpc ~session_id ~host:state.master
    ~device_config:["server", storage.storage_ip; "serverpath", "/nfs"]
    ~_type:"nfs" ~physical_size:0L ~name_label:"nfs-sr"
    ~name_description:"" ~content_type:""
    ~sm_config:[] ~shared:true >>= fun ref ->
  SR.get_uuid ~rpc ~session_id ~self:ref >>= fun uuid ->
  return (ref, uuid)


let find_or_create_sr state ty =
  let rpc,session_id = state.master_rpc,state.master_session in
  let srty_of_ty = function
    | ISCSI -> "lvmoiscsi"
    | NFS -> "nfs"
  in
  SR.get_all_records ~rpc ~session_id >>= fun sr_ref_recs ->
  let pred = fun (sr_ref, sr_rec) -> sr_rec.API.sR_type = (srty_of_ty ty) in
  if List.exists pred sr_ref_recs
  then begin
    let (rf, rc) = List.find pred sr_ref_recs in
    Lwt.return (rf, rc.API.sR_uuid)
  end else begin
    match ty with
    | ISCSI -> create_iscsi_sr state
    | NFS -> create_nfs_sr state
  end


let get_sr state ty =
  match (ty, state.iscsi_sr, state.nfs_sr) with
  | ISCSI, Some _, _  
  | NFS, _, Some _ -> Lwt.return state
  | ISCSI, _, _ -> find_or_create_sr state ty >>= fun s -> Lwt.return { state with iscsi_sr = Some s }
  | NFS, _, _ -> find_or_create_sr state ty >>= fun s -> Lwt.return { state with nfs_sr = Some s }


  (** [find template rpc session name] returns the first template
   * that has name [name] or fails with [Failure msg]
   *)
let find_template rpc session_id name =
  VM.get_all_records rpc session_id >>= fun vms ->
  let is_template = function
    | _,  { API.vM_name_label    = name
          ; API.vM_is_a_template = true 
          } -> true
    | _, _ -> false
  in match List.filter is_template vms with
  | []          -> fail (sprintf "No template named '%s' found" name)
  | (x,_) :: _  -> return x


let create_mirage_vm state path_to_kernel =
  let rpc = state.master_rpc in
  let session_id = state.master_session in
  find_template rpc session_id "Other install media" >>= fun template ->
  VM.clone rpc session_id template "mirage" >>= fun vm ->
  VM.provision rpc session_id vm >>= fun _ ->
  VM.set_PV_kernel rpc session_id vm path_to_kernel >>= fun () ->
  VM.set_HVM_boot_policy rpc session_id vm "" >>= fun () ->
  VM.set_memory_limits ~rpc ~session_id 
    ~self:vm 
    ~static_min:meg32 
    ~static_max:meg32 
    ~dynamic_min:meg32 
    ~dynamic_max:meg32 >>= fun () ->
  Lwt.return ({state with mirage_vm = Some vm}, vm)

let find_or_create_mirage_vm state path_to_kernel =
  let rpc = state.master_rpc in
  let session_id = state.master_session in
  VM.get_all_records_where ~rpc ~session_id ~expr:"field \"name__label\"=\"mirage\""
  >>= function
  | (vm,_)::_ -> Lwt.return ({state with mirage_vm = Some vm}, vm)
  | []        -> create_mirage_vm state path_to_kernel


(* not used *)
let get_control_domain state host =
  let rpc = state.master_rpc in
  let session_id = state.master_session in
  let is_control_domain (vm_ref, vm_rec) = 
    vm_rec.API.vM_resident_on=host && vm_rec.API.vM_is_control_domain in
  printf "About to get all records...\n%!";
  VM.get_all_records ~rpc ~session_id >>= fun vms ->
  printf "Finding control domain\n%!";
  Lwt.wrap2 List.find is_control_domain vms >>= fun (x,_) -> Lwt.return x


