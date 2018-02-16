open Xen_api_lwt_unix
open Context

type 'a api = rpc:rpc -> session_id:API.ref_session -> 'a

module type S = sig
  val name : string

  val execute : Context.t -> unit Lwt.t
end

module type BEHAVIOUR = sig
  type t

  (** operation type according to XenAPI, or a synthetic operation that is
   * always allowed (e.g. Host.disable) *)
  type operation

  val rpc_of_operation : operation -> Rpc.t

  val name : string

  val get_uuid : (self:t -> string Lwt.t) api

  (** retrieve list of allowed operations through XenAPI,
   *  avoid duplicating prechecks that XAPI itself should perform *)
  val get_allowed_operations : (self:t -> operation list Lwt.t) api

  (** retrieve list of objects or testing, creating them if needed *)
  val get_all : t list Lwt.t api

  (** perform operations supplying valid parameters to operations, such that the
   * operation is reasonably expected to succeed *)
  val perform : Context.session -> t -> operation -> unit Lwt.t
end

let on_self ctx self op = rpc ctx (fun ~rpc ~session_id -> op ~rpc ~session_id ~self)

module Make (B : BEHAVIOUR) : S = struct
  let name = B.name

  let pp_operation = Fmt.using B.rpc_of_operation PP.rpc_t

  let execute t =
    step t B.name
    @@ fun ctx ->
    let seen = Hashtbl.create 17 in
    let rec perform_allowed self =
      Lwt.catch
        (fun () ->
          on_self ctx self B.get_uuid
          >>= fun uuid ->
          on_self ctx self B.get_allowed_operations
          >>= fun ops ->
          debug (fun m -> m "Available operations on %s: %a" uuid Fmt.(list pp_operation) ops) ;
          match List.find_all (fun e -> not (Hashtbl.mem seen e)) ops with
          | [] -> Lwt.return_unit
          | op :: _ ->
              Hashtbl.add seen op () ;
              debug (fun m -> m "Performing %a on %s" pp_operation op uuid) ;
              Lwt.catch
                (fun () -> B.perform ctx self op)
                (function
                    | Api_errors.Server_error (code, (msg :: _ as lst))
                      when code = Api_errors.sr_backend_failure && msg = "NotImplementedError" ->
                        warn (fun m ->
                            m "Operation %a is not implemented: %a!" pp_operation op
                              Fmt.(list string)
                              lst ) ;
                        Lwt.return_unit
                    | e ->
                        err (fun m -> m "Operation %a failed: %a" pp_operation op Fmt.exn e) ;
                        Lwt.return_unit
                        (* and keep going *))
              >>= fun () -> perform_allowed self )
        (function
            | Api_errors.Server_error (code, _) when code = Api_errors.handle_invalid ->
                (* fine, we've run destroy/forget *)
                Lwt.return_unit
            | e -> Lwt.fail e)
    in
    rpc ctx B.get_all
    >>= fun all ->
    debug (fun m -> m "Performing operations serially") ;
    Lwt_list.iter_s perform_allowed all
    >>= fun () ->
    rpc ctx B.get_all
    >>= fun all ->
    debug (fun m -> m "Performing operations in parallel") ;
    Lwt_list.iter_p perform_allowed all
end

module Cluster_host_test = struct
  type t = API.ref_Cluster_host

  type operation = API.cluster_host_operation

  let rpc_of_operation = API.rpc_of_cluster_host_operation

  include Cluster_host

  let name = "Cluster_host"

  let perform ctx self = function
    | `enable -> rpc ctx @@ Cluster_host.enable ~self
    | `disable ->
        (* TODO: when SR attached that requires cluster stack this should not be present *)
        rpc ctx @@ Cluster_host.disable ~self
end

let todo msg =
  info (fun m -> m "TODO: %s" msg) ;
  Lwt.return_unit


let get_management_pifs ctx =
  rpc ctx PIF.get_all >>= Lwt_list.filter_p (fun self -> rpc ctx @@ PIF.get_management ~self)


module Cluster_test = struct
  type t = API.ref_Cluster

  type operation = API.cluster_operation [@@deriving rpc]

  let rpc_of_operation = API.rpc_of_cluster_operation

  include Cluster

  let name = "Cluster"

  let contains ctx self = on_self ctx self Cluster.get_cluster_hosts

  let on_child ctx self op =
    contains ctx self
    >>= function
      | child :: _ -> on_self ctx child op
      | [] ->
          debug (fun m -> m "no child objects: nothing to do") ;
          Lwt.return_unit


  let perform ctx self = function
    | `destroy -> on_self ctx self Cluster.destroy
    | `enable -> on_child ctx self Cluster_host.enable
    | `disable -> on_child ctx self Cluster_host.disable
    | `remove -> on_child ctx self Cluster_host.destroy
    | `add -> todo "join host to pool"
end

module Pool_test = struct
  type t = API.ref_pool

  type operation = API.pool_allowed_operations

  let rpc_of_operation = API.rpc_of_pool_allowed_operations

  include Pool

  let contains ctx _self =
    (* there is only pool for now *)
    rpc ctx Host.get_all


  let name = "Pool"

  let perform ctx _self = function
    | `cluster_create -> (
        get_management_pifs ctx
        >>= function
          | [] -> Lwt.fail_with "No management interface found"
          | pif :: _ as pifs ->
              debug (fun m -> m "Setting disallow unplug") ;
              Lwt_list.iter_p
                (fun self -> rpc ctx @@ PIF.set_disallow_unplug ~self ~value:true)
                pifs
              >>= fun () ->
              rpc ctx @@ PIF.get_network ~self:pif
              >>= fun network ->
              rpc ctx
              @@ Cluster.pool_create ~network ~cluster_stack:"corosync" ~token_timeout:20.0
                   ~token_timeout_coefficient:1.0
              >>= fun _ ->
              info (fun m -> m "Created cluster") ;
              Lwt.return_unit )
    | `ha_disable -> rpc ctx @@ Pool.disable_ha
    | `ha_enable -> rpc ctx @@ Pool.enable_ha ~heartbeat_srs:[] ~configuration:[]
end

let name_label = "create-test A\226\156\148 \"'<{[aa;#"

let name_description = "description for " ^ name_label

let tags = ["tag for " ^ name_label; "tagg"]

module SR_test = struct
  type t = [`SR] Ref.t

  type operation =
    [ `destroy
    | `forget
    | `pbd_create
    | `pbd_destroy
    | `plug
    | `scan
    | `unplug
    | `update
    | `vdi_clone
    | `vdi_create
    | `vdi_data_destroy
    | `vdi_destroy
    | `vdi_disable_cbt
    | `vdi_enable_cbt
    | `vdi_introduce
    | `vdi_list_changed_blocks
    | `vdi_mirror
    | `vdi_resize
    | `vdi_set_on_boot
    | `vdi_snapshot ]
    [@@deriving rpc]

  include SR

  let name = "SR"

  let on_pbds ctx sr op =
    on_self ctx sr SR.get_PBDs >>= Lwt_list.iter_p (fun self -> on_self ctx self op)


  let get_all ~rpc ~session_id =
    SR.get_all_records_where ~rpc ~session_id ~expr:{|field "type" = "gfs2"|}
    >>= fun srs -> Lwt.return (List.rev_map fst srs)


  let vdi () =
    debug (fun m -> m "Skipping operation: tested on the VDI object directly") ;
    Lwt.return_unit


  (* this should check the allowed ops of the child as well! *)
  let perform ctx sr (op: operation) =
    match op with
    | `destroy -> rpc ctx @@ SR.destroy ~sr
    | `forget -> rpc ctx @@ SR.forget ~sr
    | `pbd_create -> todo "PBD.create"
    | `pbd_destroy -> todo "PBD.destroy"
    | `plug -> on_pbds ctx sr PBD.plug
    | `scan -> rpc ctx @@ SR.scan ~sr
    | `unplug -> on_pbds ctx sr PBD.unplug
    | `update -> rpc ctx @@ SR.update ~sr
    | `vdi_clone -> vdi ()
    | `vdi_create ->
        rpc ctx
        @@ VDI.create ~name_label ~name_description ~sR:sr ~virtual_size:65536L ~_type:`user
             ~sharable:true ~read_only:false ~other_config:[] ~xenstore_data:[] ~sm_config:[] ~tags
        >>= fun _ ->
        rpc ctx
        @@ VDI.create ~name_label ~name_description ~sR:sr ~virtual_size:65536L ~_type:`user
             ~sharable:true ~read_only:false ~other_config:[] ~xenstore_data:[] ~sm_config:[] ~tags
        >>= fun _ -> Lwt.return_unit
    | `vdi_data_destroy -> vdi ()
    | `vdi_destroy -> vdi ()
    | `vdi_disable_cbt -> vdi ()
    | `vdi_enable_cbt -> vdi ()
    | `vdi_list_changed_blocks -> vdi ()
    | `vdi_set_on_boot -> vdi ()
    | `vdi_snapshot -> vdi ()
    | `vdi_introduce ->
        on_self ctx sr SR.get_VDIs
        >>= fun vdis ->
        Lwt_list.iter_p
          (fun vdi ->
            on_self ctx vdi @@ VDI.get_record
            >>= fun vdir ->
            rpc ctx @@ VDI.forget ~vdi
            >>= fun () ->
            rpc ctx
            @@ VDI.introduce ~uuid:vdir.API.vDI_uuid ~name_label:vdir.API.vDI_name_label
                 ~name_description:vdir.API.vDI_name_description ~_type:vdir.API.vDI_type
                 ~sharable:vdir.API.vDI_sharable ~read_only:vdir.API.vDI_read_only
                 ~other_config:vdir.API.vDI_other_config ~location:vdir.API.vDI_location
                 ~sm_config:vdir.API.vDI_sm_config ~managed:vdir.API.vDI_managed
                 ~virtual_size:vdir.API.vDI_virtual_size
                 ~physical_utilisation:vdir.API.vDI_physical_utilisation
                 ~metadata_of_pool:vdir.API.vDI_metadata_of_pool
                 ~is_a_snapshot:vdir.API.vDI_is_a_snapshot
                 ~snapshot_time:vdir.API.vDI_snapshot_time ~snapshot_of:vdir.API.vDI_snapshot_of
                 ~sR:sr ~xenstore_data:vdir.API.vDI_xenstore_data
            >>= fun _ -> Lwt.return_unit )
          vdis
    | `vdi_resize -> vdi ()
    | `vdi_mirror -> todo "Seems unused"
end

module VDI_test = struct
  type t = API.ref_VDI

  type operation = API.vdi_operations

  let rpc_of_operation = API.rpc_of_vdi_operations

  include VDI

  let get_all ~rpc ~session_id =
    SR_test.get_all ~rpc ~session_id
    >>= Lwt_list.map_p (fun sr ->
            let expr = Printf.sprintf {|field "SR" = "%s"|} (Ref.string_of sr) in
            VDI.get_all_records_where ~rpc ~session_id ~expr )
    >>= fun vdis -> Lwt.return (vdis |> List.flatten |> List.rev_map fst)


  let name = "VDI"

  let perform ctx self (op: operation) =
    match op with
    | `clone -> rpc ctx @@ VDI.clone ~driver_params:[] ~vdi:self >>= fun _ -> Lwt.return_unit
    | `data_destroy -> on_self ctx self VDI.data_destroy
    | `destroy -> on_self ctx self VDI.destroy (* ISOSR fails with cannot mark as hidden *)
    | `disable_cbt -> on_self ctx self VDI.disable_cbt
    | `enable_cbt -> on_self ctx self VDI.enable_cbt
    | `set_on_boot -> on_self ctx self @@ VDI.set_on_boot ~value:`reset
    | `snapshot -> rpc ctx @@ VDI.snapshot ~driver_params:[] ~vdi:self >>= fun _ -> Lwt.return_unit
    | `resize ->
        (* sharable VDI cannot be resized *)
        on_self ctx self VDI.get_virtual_size
        >>= fun size -> rpc ctx @@ VDI.resize ~vdi:self ~size:(Int64.add size 65536L)
    | `resize_online ->
        on_self ctx self VDI.get_virtual_size
        >>= fun size -> rpc ctx @@ VDI.resize_online ~vdi:self ~size:(Int64.add size 65536L)
    | `mirror -> todo "Seems unused?"
    | `forget -> rpc ctx @@ VDI.forget ~vdi:self
    | `copy -> todo "VDI.copy"
    | `list_changed_blocks -> todo "CBT"
    | `blocked -> todo "??"
    | `generate_config -> todo "VDI.generate_config"
    | `force_unlock ->
        todo "FIXME: doesn't work, MESSAGE_DEPRECATED, why is this part of allowed-ops?"
    | `update -> rpc ctx @@ VDI.update ~vdi:self
end

module Host_test = struct
  type t = API.ref_host

  type operation = [API.host_allowed_operations | `disable] [@@deriving rpc]

  include Host

  let name = "Host"

  let vm () =
    debug (fun m -> m "Tested as part of VM ops") ;
    Lwt.return_unit


  let get_allowed_operations ~rpc ~session_id ~self =
    get_allowed_operations ~rpc ~session_id ~self
    >>= fun ops ->
    Host.get_enabled ~rpc ~session_id ~self
    >>= fun enabled ->
    if enabled then
      `disable :: ops |> List.filter (function `reboot | `shutdown -> false | _ -> true)
      |> Lwt.return
    else Lwt.return ops


  let rec wait_live ctx ~host () =
    rpc ctx @@ Host.get_enabled ~self:host
    >>= function true -> Lwt.return_unit | false -> Lwt_unix.sleep 0.3 >>= wait_live ctx ~host


  let perform ctx host = function
    | `evacuate -> rpc ctx @@ Host.evacuate ~host
    | `power_on -> rpc ctx @@ Host.power_on ~host
    | `provision -> todo "??"
    | `reboot -> rpc ctx @@ Host.reboot ~host >>= wait_live ctx ~host
    | `shutdown -> rpc ctx @@ Host.shutdown ~host >>= wait_live ctx ~host
    | `disable -> rpc ctx @@ Host.disable ~host
    | `vm_migrate -> vm ()
    | `vm_resume -> vm ()
    | `vm_start -> vm ()
end

let tests =
  [ (module Make (Cluster_host_test) : S)
  ; (module Make (Cluster_test) : S)
  ; (module Make (Pool_test) : S)
  ; (module Make (SR_test) : S)
  ; (module Make (VDI_test) : S)
  ; (module Make (Host_test) : S) ]

(*  TODO: vm tests based on mirage test vm *)
