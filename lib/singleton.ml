open Lwt.Infix

type 'a t = {m: Lwt_mutex.t; update: unit -> 'a Lwt.t; mutable v: 'a option}

let create update = {m= Lwt_mutex.create (); update; v= None}

let invalidate t old =
  match t.v with
  | Some v when v == old -> (* physical equality, remove invalid value *)
                            t.v <- None
  | _ ->
      (* the value changed meanwhile, do not invalidate the new one.
     * This ensures that if we have hundreds of session expiring,
     * we login only once to get a new one
    *)
      ()


let get t =
  Lwt_mutex.with_lock t.m (fun () ->
      match t.v with
      | None ->
          t.update ()
          >>= fun r ->
          t.v <- Some r ;
          Lwt.return r
      | Some r -> Lwt.return r )
