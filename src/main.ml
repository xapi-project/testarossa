open Testarossa
open Lwt.Infix

let ctx = Lwt.new_key ()

(* grey *)
let pp_time = Fmt.(styled `Black string |> styled `Bold)

let msg_of_level = function
  | Logs.App -> (Logs_fmt.app_style, "")
  | Debug -> (Logs_fmt.debug_style, "debug")
  | Warning -> (Logs_fmt.warn_style, "warn")
  | Info -> (Logs_fmt.info_style, "info")
  | Error -> (Logs_fmt.err_style, "error")


let pp_level ppf level =
  let style, msg = msg_of_level level in
  Fmt.pf ppf "%5a" Fmt.(styled style string) msg


let pp_header ppf (level, header) =
  let now = Debug.gettimestring () in
  let name = "" in
  let module_ = "" in
  let id, task = match Lwt.get ctx with Some (id, task) -> (id, task) | None -> (0, "") in
  Fmt.pf ppf "[%a%a|%a|%d %s|%s|%s] " pp_time now pp_level level
    Fmt.(option string |> styled Logs_fmt.app_style)
    header id name task module_


let setup style_renderer level =
  Printexc.record_backtrace true;
  Fmt_tty.setup_std_outputs ?style_renderer () ;
  let ch = Unix.open_process_in "tput cols" in
  input_line ch |> int_of_string |> Format.set_margin;
  Logs.set_level ~all:true level ;
  Logs.set_reporter (Logs_fmt.reporter ~pp_header ()) ;
  Context.debug (fun m -> m ~header:"x" "Initialized")


open Cmdliner

let common =
  let docs = Manpage.s_common_options in
  Term.(const setup $ Fmt_cli.style_renderer ~docs () $ Logs_cli.level ~docs ())


let init () = Logs.info (fun m -> m "started")

let () =
  let sdocs = Manpage.s_common_options in
  let exits = Term.default_exits in
  let default_cmd =
    let doc = "a small system-level test framework using Xen-on-Xen" in
    ( Term.(ret (const (fun _ -> `Help (`Pager, None)) $ common))
    , Term.info "testarossa" ~version:"v1.2" ~doc ~sdocs ~exits )
  in
  Term.exit
  @@
  Term.(
    eval_choice ~catch:true default_cmd
      [ Cmd_init.init ~sdocs ~exits ~common
      ; Cmd_lwt.prepare ~sdocs ~exits ~common
      ; Cmd_init.list ~sdocs ~exits ~common
      ; Cmd_lwt.run ~sdocs ~exits ~common ])
