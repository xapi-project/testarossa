open Xen_api_lwt_unix
open Context
open Cmd_types

type t = {server: string; edition: string; port: int}

let edition_key = "edition"

let check_features t required self =
  debug (fun m -> m "listing license params") ;
  rpc t @@ Host.get_license_params ~self
  >>= fun params ->
  let features = Features.of_assoc_list params in
  debug (fun m -> m "features: %a" PP.features features) ;
  debug (fun m -> m "required features: %a" PP.features required) ;
  let _, missing = List.partition (fun feature -> List.mem feature features) required in
  if missing = [] then Lwt.return_true
  else (
    info (fun m -> m "Required features missing: %a" PP.features missing) ;
    Lwt.return_false )


let maybe_license_host ctx conf self =
  rpc ctx @@ Host.get_edition ~self
  >>= fun existing_edition ->
  get_host_pp ctx self
  >>= fun h ->
  if existing_edition = conf.license_edition then (
    debug (fun m -> m "Host %a is already using edition %s" PP.host h conf.license_edition) ;
    Lwt.return_unit )
  else (
    debug (fun m -> m "Configuring license server on %a" PP.host h) ;
    ( match conf.license_server with
    | Some license_server ->
        rpc ctx @@ Host.remove_from_license_server ~self ~key:"port"
        >>= fun () ->
        rpc ctx
        @@ Host.add_to_license_server ~self ~key:"port"
             ~value:(string_of_int conf.license_server_port)
        >>= fun () ->
        rpc ctx @@ Host.remove_from_license_server ~self ~key:"address"
        >>= fun () ->
        rpc ctx @@ Host.add_to_license_server ~self ~key:"address" ~value:license_server
    | _ ->
        debug (fun m -> m "No license server specified") ;
        Lwt.return_unit )
    >>= fun () ->
    get_host_pp ctx self
    >>= fun h ->
    debug (fun m -> m "Applying edition %s on %a" conf.license_edition PP.host h) ;
    rpc ctx @@ Host.apply_edition ~host:self ~edition:conf.license_edition ~force:true )


let maybe_apply_license_pool t conf required =
  step t "Applying license to pool"
  @@ fun ctx ->
  get_pool_master ctx
  >>= fun (pool, master) ->
  maybe_license_host ctx conf master
  >>= fun () ->
  rpc ctx @@ Host.get_all >>= Lwt_list.for_all_p (check_features ctx required)
  >>= function
    | true ->
        debug (fun m -> m "All required features are present on all the hosts in the pool") ;
        Lwt.return_unit
    | false ->
        debug (fun m -> m "Copying license server from master to entire pool") ;
        rpc ctx @@ Host.get_license_server ~self:master
        >>= fun master_server ->
        rpc ctx @@ Host.get_all
        >>= fun hosts ->
        Lwt_list.iter_p
          (fun host ->
            get_host_pp ctx host
            >>= fun h ->
            debug (fun m -> m "Setting license server on %a to %a" PP.host h PP.dict master_server) ;
            rpc ctx @@ Host.set_license_server ~self:host ~value:master_server
            >>= fun () ->
            rpc ctx @@ Host.apply_edition ~host ~edition:conf.license_edition ~force:true )
          hosts
        >>= fun () ->
        debug (fun m -> m "Applying edition on the pool") ;
        rpc ctx @@ Pool.apply_edition ~self:pool ~edition:conf.license_edition
        >>= fun () ->
        Lwt_list.for_all_p (check_features ctx required) hosts
        >>= function
          | true ->
              debug (fun m ->
                  m "All required features are present after applying edition %s"
                    conf.license_edition ) ;
              Lwt.return_unit
          | false ->
              err (fun m ->
                  m "Features are missing even after applying edition %s" conf.license_edition ) ;
              Lwt.fail_with "Features are missing (check license)"
