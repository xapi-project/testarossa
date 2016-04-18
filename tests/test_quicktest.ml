
open Yorick
open Lwt
open Xen_api
open Xen_api_lwt_unix
open Test_common

(* kernels live in xs/boot/guest - see xen-test-vm.sh there *)

let kernel        = "/boot/guest/xen-test-vm-0-0-5.xen.gz"
let kernel        = "/boot/guest/mir-suspend.xen.gz" 

let quicktest_cmd = Printf.sprintf 
  "vagrant ssh host1 -c '%s'"
  "sudo /opt/xensource/debug/quicktest -single powercycle "
let quicktest_cmd = 
  "vagrant ssh host1 -c 'sudo /opt/xensource/debug/quicktest'"


let _ =
  let thread =
    if true then begin (* takes a long time *)
      echo "Udpating vagrant box to latest version";
      update_box "host1";
    end;
    echo "Starting up host";
    start_all 1;
    echo "Setting up infrastructure VM for iSCSI export";
    let _ = setup_infra () in
    let hosts = get_hosts 1 in
      get_pool hosts
      >>= fun state ->
      find_or_create_mirage_vm state kernel >>= fun (state,vm) ->
      echo "Creating shared NFS SR";
      get_sr state NFS
      >>= fun state ->
      begin match state.nfs_sr with
      | Some (_, uuid) -> echo "NFS SR uuid: %s%!" uuid
      | None            -> echo "No NFS SR!"
      end;
      echo "Running quicktest...";
      match !?* (?|>) "%s" quicktest_cmd with
      | (_, 0) ->
        echo "Quicktest finished successfully!";
        Lwt.return ();
      | (stdout, rc) ->
        echo "---[ BEGIN OUTPUT FROM QUICKTEST ]---";
        echo "%s" (trim stdout);
        echo "---[  END OUTPUT FROM QUICKTEST  ]---";
        echo "Quicktest failed (exit code %d)" rc;
        exit rc;
    in
      Lwt_main.run thread
