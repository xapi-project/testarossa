open Xen_api_lwt_unix

type host = {name: string; ip: string}

module PP = struct
  open Fmt

  let dict = Dump.(pair string string |> list)

  let rpc_t = using Jsonrpc.to_string string

  let feature = using API.rpc_of_feature_t rpc_t

  let records pp_elt = Dump.(using snd pp_elt |> list)

  let features = using Features.to_compact_string string

  let host ppf h = pf ppf "@[%s(%s)@]" h.name h.ip

  let pif ppf pifr = pf ppf "%s" pifr.API.pIF_uuid

  let vm_uuid = Fmt.(using (fun vmr -> vmr.API.vM_uuid) string)
  let vm_name_label = Fmt.(using (fun vmr -> vmr.API.vM_name_label) string)
  let vm_record ppf vmr =
    Fmt.pf ppf "%a(%a)" vm_uuid vmr vm_name_label vmr

  let rpc_call ppf call =
    pf ppf "%s%a" call.Rpc.name
      (using Jsonrpc.to_string string |> list ~sep:(always ", ") |> parens)
      call.Rpc.params


  let rpc_response ppf r =
    pf ppf "%s: %a"
      (if r.Rpc.success then "success" else "failure")
      (using Jsonrpc.to_string string) r.Rpc.contents
end

let src = Logs.Src.create "testarossa" ~doc:"logs testarossa events"

include (val Logs.src_log src : Logs.LOG)

type 'a log = 'a Logs.log

let version = "1.1"

let originator = "testarossa"

type rpc = Rpc.call -> Rpc.response Lwt.t

type t = (rpc * API.ref_session) Singleton.t

let src = Logs.Src.create "RPC" ~doc:"logs RPC calls"

module Log_rpc = (val Logs.src_log src : Logs.LOG)

type session = rpc * API.ref_session

let rpc (rpc, session_id) f = f ~rpc ~session_id

let id = ref 0

let wrap_rpc dest f call =
  let this_id = !id in
  incr id ;
  let open Log_rpc in
  let header = "RPC " ^ dest in
  debug (fun m -> m ~header "%d> %a" this_id PP.rpc_call call);
  let c = Mtime_clock.counter () in
  let on_reply reply =
    let dt = Mtime_clock.count c in
    debug (fun m -> m ~header "%d<[+%a] %a" this_id Mtime.Span.pp dt PP.rpc_response reply);
    Lwt.return reply
  in
  let on_error err =
    let dt = Mtime_clock.count c in
    info (fun m -> m ~header "%d<[+%a] %a" this_id Mtime.Span.pp dt Fmt.exn err);
    Lwt.fail err
  in
  Lwt.try_bind (fun () -> f call) on_reply on_error


let get_pool_master t =
  rpc t Pool.get_all
  >>= function
    | [pool_ref] ->
        rpc t @@ Pool.get_master ~self:pool_ref
        >>= fun master_ref -> Lwt.return (pool_ref, master_ref)
    | [] -> Lwt.fail_with "No pools found"
    | _ :: _ :: _ -> Lwt.fail_with "Too many pools"


let max_expiration_retry = 3

(* call [f ~rpc ~session_id] and retry by logging in again on [Api_errors.session_invalid] *)
let step t description f =
  let open Lwt.Infix in
  let rec retry = function
    | n when n > max_expiration_retry -> Lwt.fail_with "Maximum number of retries exceeded"
    | n ->
        Singleton.get t
        >>= fun info ->
        Lwt.catch
          (fun () ->
            debug (fun m -> m "Entering %s" description) ;
            let c = Mtime_clock.counter () in
            Lwt.finalize
              (fun () -> f info)
              (fun () ->
                let dt = Mtime_clock.count c in
                debug (fun m -> m "Finished %s in %a" description Mtime.Span.pp dt) ;
                Lwt.return_unit ) )
          (function
              | Api_errors.Server_error (code, _) when code = Api_errors.session_invalid ->
                  debug (fun m -> m "Session is not valid (try #%d)!" n) ;
                  Singleton.invalidate t info ;
                  retry (n + 1)
              | e -> Lwt.fail e)
  in
  retry 0


let with_login ?(timeout= 60.0) ~uname ~pwd master f =
  let open Lwt.Infix in
  let mrpc = make ~timeout ("https://" ^ master) |> wrap_rpc master in
  let login () =
    debug (fun m -> m "Logging in to %s as %s" master uname) ;
    Session.login_with_password ~rpc:mrpc ~uname ~pwd ~version ~originator
    >>= fun session_id -> Lwt.return (mrpc, session_id)
  in
  let result = Singleton.create login in
  Singleton.get result
  >>= fun _ ->
  Lwt.finalize
    (fun () -> f result)
    (fun () -> step result "logout" (fun ctx -> rpc ctx Session.logout))


let get_host_pp ctx self =
  let name = rpc ctx @@ Host.get_name_label ~self and ip = rpc ctx @@ Host.get_address ~self in
  name >>= fun name -> ip >>= fun ip -> Lwt.return {name; ip}
