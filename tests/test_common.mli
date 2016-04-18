
type host_state = Slave of string | Master
type host = { name : string; ip : string; uuid : string; }
type storage_server = { storage_ip : string; iscsi_iqn : string; }

type state = {
  hosts : host list;
  pool : string;
  master : string;
  master_uuid : string;
  master_rpc : Rpc.call -> Rpc.response Lwt.t;
  master_session : string;
  pool_setup : bool;
  iscsi_sr : (string * string) option;
  nfs_sr : (string * string) option;
  mirage_vm : string option;
}
type sr_type = NFS | ISCSI

(** [meg n] denotes [n] megabytes of memory *)
val meg : int -> int64

(** [seq n] creates a list [1; 2; ..; n]. [n] must not be negative. *)
val seq : int -> int list

(** [fail msg] makes an Lwt thread fail with exception [Failure msg]*)
val fail : string -> 'a Lwt.t

(** [update_box host] uses vagran to update [host] *)
val update_box : string -> unit

(** [start_all n] uses vagrant to spin up [n] machines, plus a machine
 * ["innfrastructure"] *)
val start_all : int -> unit

(** [setup_infra ()] sets up host ["infrastructure"] *) 
val setup_infra : unit -> storage_server

(** [get_hosts n] get information for hosts [1 .. n] *)
val get_hosts : int -> host list

(** [get_state hosts] gets the state for each [host]. FIXME this should
 * work on a single host as it makes error handline much easier *)
val get_state : host list -> (host * host_state) list Lwt.t

(** [setup pool hosts] sets up a pool from a list of [hosts] *)
val setup_pool : host list -> state Lwt.t

(* TODO document these *)
val get_pool : host list -> state Lwt.t
val create_iscsi_sr : state -> (string * string) Lwt.t
val create_nfs_sr : state -> (string * string) Lwt.t
val find_or_create_sr : state -> sr_type -> (string * string) Lwt.t
val get_sr : state -> sr_type -> state Lwt.t

 
(* I'd like to refactor the code below. *)

val find_template :
  (Rpc.call -> Rpc.response Lwt.t) -> string -> string -> string Lwt.t
val create_mirage_vm : state -> string -> (state * string) Lwt.t
val find_or_create_mirage_vm : state -> string -> (state * string) Lwt.t

(* [get_control_domain] is unused 
 * val get_control_domain : state -> API.ref_host -> string Lwt.t
 *)
