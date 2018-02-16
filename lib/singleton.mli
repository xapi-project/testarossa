type 'a t

val create : (unit -> 'a Lwt.t) -> 'a t

val invalidate : 'a t -> 'a -> unit

val get : 'a t -> 'a Lwt.t
