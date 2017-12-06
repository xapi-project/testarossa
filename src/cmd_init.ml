open Testarossa
open Cmd_types
open Rresult

let main () config = config |> rpc_of_t |> Jsonrpc.to_string |> print_endline

open Cmdliner

let iscsi =
  let doc = "Address of iSCSI target" in
  Arg.(value & opt (some ip) None & info ["iscsi"] ~doc)


let iqn =
  let doc = "iSCSI IQN" in
  let docv = "IQN" in
  Arg.(value & opt (some string) None & info ~docv ~doc ["iqn"])


let scsiid =
  let doc = "SCSIid" in
  let docv = doc in
  Arg.(value & opt (some string) None & info ~doc ~docv ["scsiid"])


let license_server =
  let doc = "License server address" in
  let docv = "host" in
  Arg.(value & opt (some string) None & info ~doc ~docv ["license-server"])


let license_server_port =
  let doc = "License server port" in
  let docv = "port" in
  Arg.(value & opt int 27000 & info ~doc ~docv ["license-server-port"])


let license_edition =
  let doc = "License edition" in
  let docv = "edition" in
  Arg.(value & opt string "enterprise-per-socket" & info ~doc ~docv ["license-edition"])


let physical =
  let doc = "Physical XenServer host containing virtual XenServer hosts" in
  Arg.(value & opt (some string) None & info ["physical"] ~doc)


let uname =
  let doc = "XenServer username" in
  Arg.(required & opt (some string) None & info ["username"] ~doc)


let pwd =
  let doc = "XenServer password" in
  Arg.(required & opt (some string) None & info ["password"] ~doc)


let hosts =
  let doc = "IPv4 address of (virtual) hosts" in
  Arg.(non_empty & pos_all ip [] & info [] ~doc ~docv:"HOST")


let build iscsi iqn scsiid license_server license_server_port license_edition physical uname pwd
    hosts =
  { iscsi
  ; iqn
  ; scsiid
  ; license_server
  ; license_server_port
  ; license_edition
  ; physical
  ; uname
  ; pwd
  ; hosts }


let init ~common ~sdocs ~exits =
  let doc = "initialize a new test profile" in
  let build =
    let open Term in
    const build $ iscsi $ iqn $ scsiid $ license_server $ license_server_port $ license_edition
    $ physical $ uname $ pwd $ hosts
  in
  (Term.(const main $ common $ build), Term.info "init" ~doc ~sdocs ~exits)


let list_available () =
  let open Allowed_ops in
  tests |> List.map (fun (module M : S) -> M.name)
  |> fun names ->
  Fmt.pr "Available tests: %a@," Fmt.(list ~sep:(Fmt.unit ",@ ") string |> hbox) names


let list ~common ~sdocs ~exits =
  let doc = "List available tests" in
  (Term.(const list_available $ common), Term.info "list" ~doc ~sdocs ~exits)
