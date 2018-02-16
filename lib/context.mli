type rpc = Rpc.call -> Rpc.response Lwt.t

type t

type session

val with_login :
  ?timeout:float -> uname:string -> pwd:string -> string -> (t -> 'a Lwt.t) -> 'a Lwt.t

val step : t -> string -> (session -> 'a Lwt.t) -> 'a Lwt.t

val rpc : session -> (rpc:rpc -> session_id:API.ref_session -> 'a Lwt.t) -> 'a Lwt.t

type 'a log = 'a Logs.log

val debug : 'a log

val info : 'a log

val warn : 'a log

val err : 'a log

type host = {name: string; ip: string}

val get_host_pp : session -> API.ref_host -> host Lwt.t

val get_pool_master : session -> (API.ref_pool * API.ref_host) Lwt.t

module PP : sig
  val dict : (string * string) list Fmt.t

  val rpc_t : Rpc.t Fmt.t

  val feature : API.feature_t Fmt.t

  val records : 'b Fmt.t -> ('a Ref.t * 'b) list Fmt.t

  val features : Features.feature list Fmt.t

  val host : host Fmt.t

  val pif : API.pIF_t Fmt.t

  val vm_record : API.vM_t Fmt.t
end
