open Xen_api_lwt_unix
open Context

let is_ours ctx self =
  rpc ctx @@ VM.get_name_label ~self
  >>= fun name -> Lwt.return (Astring.String.is_prefix ~affix:"testarossa-pool-" name)


let list_vms ctx =
  rpc ctx
  @@ VM.get_all_records_where
       ~expr:
         {|field "is_a_snapshot" = "false" and field "is_a_template" = "false" and field "is_control_domain" = "false"|}
  >>= fun vms ->
  Lwt.return
  @@ List.filter
       (fun (_, vmr) -> not (List.mem ("auto_poweron", "true") vmr.API.vM_other_config))
       vms


let ensure_pool_snapshot t =
  step t "ensure pool has snapshot"
  @@ fun ctx ->
  list_vms ctx
  >>= fun vms ->
  Lwt_list.for_all_p
    (fun (_vm, vmr) ->
      debug (fun m -> m "Checking snapshots for VM %s" vmr.API.vM_name_label) ;
      Lwt_list.exists_p (is_ours ctx) vmr.API.vM_snapshots )
    vms
  >>= function
    | true ->
        debug (fun m -> m "VMs all have snapshots, good!") ;
        Lwt.return_unit
    | false ->
        debug (fun m -> m "Some VM doesn't have a snapshot, taking snapshot of pool now") ;
        let new_name = Printf.sprintf "testarossa-pool-%f" (Unix.gettimeofday ()) in
        debug (fun m -> m "New snapshot name: %s" new_name) ;
        Lwt_list.iter_p
          (fun (vm, _) -> rpc ctx @@ VM.snapshot ~vm ~new_name >>= fun _ -> Lwt.return_unit)
          vms
        >>= fun () ->
        debug (fun m -> m "Created snapshot(s) %s" new_name) ;
        Lwt.return_unit


let rollback_pool t =
  step t "rollback pool"
  @@ fun ctx ->
  list_vms ctx
  >>= fun vms ->
  debug (fun m -> m "Got %d VMs" (List.length vms)) ;
  Lwt_list.iter_p
    (fun (vm, vmr) ->
      Lwt_list.filter_p (is_ours ctx) vmr.API.vM_snapshots
      >>= function
        | [] ->
            warn (fun m -> m "No snapshots") ;
            Lwt.return_unit
        | snapshot :: _ ->
            debug (fun m -> m "Reverting %s to snapshot" vmr.API.vM_name_label) ;
            rpc ctx @@ VM.revert ~snapshot
            >>= fun () ->
            debug (fun m -> m "Powering on VM %s" vmr.API.vM_name_label) ;
            rpc ctx @@ VM.start ~vm ~force:false ~start_paused:false )
    vms
