open Lwt.Infix
open Testarossa
open Cmd_types
open Context
open Xen_api_lwt_unix

let ensure_vm_off ctx vifr =
  let self = vifr.API.vIF_VM in
  rpc ctx @@ VM.get_power_state ~self
  >>= function
  | `Halted -> Lwt.return_unit
  | _ ->
    rpc ctx @@ VM.shutdown ~vm:self

let ensure_vm_on ctx (vm, vmr) =
  match vmr.API.vM_power_state with
  | `Halted -> rpc ctx @@ VM.start ~start_paused:false ~force:false ~vm
  | _ -> Lwt.return_unit

let ensure_vhosts_on conf =
  match conf.physical with
  | None -> Lwt.return_unit
  | Some host ->
  Context.with_login ~uname:conf.uname ~pwd:conf.pwd host (fun phys ->
      Context.step phys "ensure vhosts are powered on" @@ fun ctx ->
      Rollback.list_vms ctx
      >>= Lwt_list.iter_p (ensure_vm_on ctx)
  )

let ensure_vhost_nics conf =
  match conf.physical with
  | None -> Lwt.return_unit
  | Some host ->
  Context.with_login ~uname:conf.uname ~pwd:conf.pwd host (fun phys ->
      Context.step phys "ensure vhost has enough NICs" @@ fun ctx ->
      Rollback.list_vms ctx
      >>= Lwt_list.iter_p (fun (vm, vmr) ->
          match vmr.API.vM_VIFs with
          | [] -> Lwt.fail_with "No NICs"
          | [ one ] ->
            rpc ctx @@ VIF.get_network ~self:one
            >>= fun network ->
            rpc ctx @@ VIF.create ~device:"1" ~network ~vM:vm ~mAC:""
              ~mTU:1500L ~other_config:[] ~qos_algorithm_type:""
              ~qos_algorithm_params:[] ~locking_mode:`network_default
              ~ipv4_allowed:[] ~ipv6_allowed:[]
            >>= fun vif ->
            debug (fun m -> m "VIF %s created" (Ref.string_of vif));
            (* can't hotplug due to pure HVM mode *)
            rpc ctx @@ VM.hard_shutdown ~vm
            >>= fun () ->
            rpc ctx @@ VM.start ~start_paused:false ~force:false ~vm
          | _ -> Lwt.return_unit
      )
  )

let ensure_bonding_on_master conf =
  let master = List.hd conf.hosts |> Ipaddr.V4.to_string in
  Context.with_login ~uname:conf.uname ~pwd:conf.pwd master (fun t ->
      step t "Create bond on master if needed" @@ fun ctx ->
      rpc ctx @@ Pool.get_all
      >>= fun pools ->
      rpc ctx @@ Pool.get_master ~self:(List.hd pools)
      >>= fun host ->
      rpc ctx @@ PIF.scan ~host
      >>= fun () ->
      rpc ctx @@ Bond.get_all
      >>= function
      | [] ->
        info (fun m -> m "No bond, creating one");
        rpc ctx @@ Host.get_management_interface ~host
        >>= fun pif ->
        rpc ctx @@ PIF.get_record ~self:pif
        >>= fun pifr ->
        rpc ctx @@ Host.get_PIFs ~self:host
        >>= fun members ->
        rpc ctx @@ Network.create ~name_label:"bonded network"
          ~name_description:"" ~mTU:1500L ~other_config:[]
          ~bridge:"" ~managed:true ~tags:[]
        >>= fun network ->
        rpc ctx @@ Bond.create ~network ~members ~mAC:"" ~mode:`balanceslb ~properties:[]
        >>= fun bond ->
        debug (fun m -> m "Created bond %s" (Ref.string_of bond));
        Lwt.return_unit
      | _ -> Lwt.return_unit
  )


let do_prepare conf =
  let master = List.hd conf.hosts |> Ipaddr.V4.to_string in
  Context.with_login ~uname:conf.uname ~pwd:conf.pwd master (fun t ->
  License.maybe_apply_license_pool t conf [Features.HA; Features.Corosync]
  >>= fun () ->
  Test_sr.enable_clustering t
  >>= fun _cluster ->
  (match conf.iscsi with
  | Some iscsi ->
      Test_sr.get_gfs2_sr t ~iscsi ?iqn:conf.iqn ?scsiid:conf.scsiid () >>= fun _gfs2 -> Lwt.return_unit
  | _ -> Lwt.return_unit)
  >>= fun () ->
  Test_sr.make_pool ~uname:conf.uname ~pwd:conf.pwd conf conf.hosts)

let run conf =
  ensure_vhost_nics conf
  >>= fun () ->
  ensure_vhosts_on conf
  >>= fun () ->
 (* Test_sr.destroy_pools ~uname:conf.uname ~pwd:conf.pwd conf.hosts :
  >>= fun () ->*)
   ensure_bonding_on_master conf
  >>= fun ()->
  do_prepare conf
