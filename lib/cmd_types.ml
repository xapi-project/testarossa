open Rresult
type ipaddr = Ipaddr.V4.t

let rpc_of_ipaddr t = Ipaddr.V4.to_string t |> Rpc.rpc_of_string

let ipaddr_of_rpc rpc = Rpc.string_of_rpc rpc |> Ipaddr.V4.of_string_exn

type t =
  { iscsi: ipaddr option
  ; iqn: string option
  ; scsiid: string option
  ; license_server: string option
  ; license_server_port: int
  ; license_edition: string
  ; physical: string option
  ; uname: string
  ; pwd: string
  ; hosts: ipaddr list }
  [@@deriving rpc]

open Cmdliner

let ip =
  let parse s = R.trap_exn Ipaddr.V4.of_string_exn s |> R.error_exn_trap_to_msg in
  let print = Ipaddr.V4.pp_hum in
  Arg.conv ~docv:"IP address" (parse, print)


let path = Arg.string
