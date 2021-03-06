(*
 * Copyright (C) Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
open Lwt

module Make(Primary: V1_LWT.BLOCK)(Secondary: V1_LWT.BLOCK) = struct
  type 'a io = 'a Lwt.t

  type page_aligned_buffer = Cstruct.t

  type error = [
    | `Unknown of string
    | `Unimplemented
    | `Is_read_only
    | `Disconnected
  ]

  let string_of_error = function
    | `Unknown x -> x
    | `Unimplemented -> "Unimplemented"
    | `Is_read_only -> "Device is read-only"
    | `Disconnected -> "Device has been disconnected"

  type info = {
    read_write: bool;
    sector_size: int;
    size_sectors: int64;
  }

  module Region_lock = struct
    (* We need to prevent the background mirror thread racing with an I/O write
       to a particular region *)

    type region = int64 * int

    let overlap (start, length) (start', length') =
      start' >= start && (start' < Int64.(add start (of_int length)))

    let before (start, length) (start', length') =
      Int64.(add start (of_int length)) < start'

    type t = {
      mutable exclusive_lock: region; (* extent we're currently copying *)
      mutable active: region list; (* extents which are being written to *)
      c: unit Lwt_condition.t;
      m: Lwt_mutex.t;
    }

    (* Exclusively lock up to [offset'] *)
    let extend_right t offset' =
      Lwt_mutex.with_lock t.m
        (fun () ->
           let rec wait () =
             let length = Int64.(to_int (sub offset' (fst t.exclusive_lock))) in
             if List.fold_left (||) false (List.map (overlap (fst t.exclusive_lock, length)) t.active) then begin
               Lwt_condition.wait ~mutex:t.m t.c
               >>= fun () ->
               wait ()
             end else return length in
           wait ()
           >>= fun length ->
           t.exclusive_lock <- (fst t.exclusive_lock, length);
           Lwt_condition.broadcast t.c ();
           return ()
        )

    (* Release lock up to [offset'] *)
    let release_left t offset' =
      Lwt_mutex.with_lock t.m
        (fun () ->
           let length = Int64.(to_int (sub (add (fst t.exclusive_lock) (of_int (snd t.exclusive_lock))) offset')) in
           t.exclusive_lock <- (offset', length);
           Lwt_condition.broadcast t.c ();
           return ()
        )

    (* Exclude the background copying thread from [offset:offset+length]. This avoids updating
       a region while it is being actively mirrored, which could cause the old data
       to overtake and overwrite the new data. *)
    let with_lock t offset length f =
      Lwt_mutex.with_lock t.m
        (fun () ->
           let rec loop () =
             if overlap t.exclusive_lock (offset, length) then begin
               Lwt_condition.wait ~mutex:t.m t.c
               >>= fun () ->
               loop ()
             end else begin
               (* if the copy might catch up with us then mark the region as locked *)
               let unlock =
                 if before t.exclusive_lock (offset, length) then begin
                   t.active <- (offset, length) :: t.active;
                   fun () ->
                     t.active <- List.filter (fun (o, l) -> o <> offset || l <> length) t.active;
                     Lwt_condition.broadcast t.c ()
                 end else
                   fun () -> () in
               Lwt.catch
                 (fun () ->
                    f () >>= fun r ->
                    unlock ();
                    return r
                 ) (fun e ->
                     unlock ();
                     fail e)
             end in
           loop ()
        )

    let make () =
      let exclusive_lock = (0L, 0) in
      let active = [] in
      let c = Lwt_condition.create () in
      let m = Lwt_mutex.create () in
      { exclusive_lock; active; c; m }

  end

  type t = {
    primary: Primary.t;
    secondary: Secondary.t;
    primary_block_size: int; (* number of primary sectors per info.sector_size *)
    secondary_block_size: int; (* number of secondary sectors per info.sector_size *)
    info: info;
    lock: Region_lock.t;
    result: [ `Ok of unit | `Error of error ] Lwt.t;
    mutable percent_complete: int;
    progress_cb: [ `Percent of int | `Complete ] -> unit;
    mutable disconnected: bool;
  }

  let start_copy t u =
    let buffer = Io_page.(to_cstruct (get 4096)) in
    (* round to the nearest sector *)
    let block = Cstruct.len buffer / t.info.sector_size in
    let buffer = Cstruct.(sub buffer 0 (block * t.info.sector_size)) in
    (* split into an array of slots *)
    let nr_slots = 8 in
    let block = block / nr_slots in
    let slots = Array.make nr_slots (Cstruct.create 0) in
    for i = 0 to nr_slots - 1 do
      slots.(i) <- Cstruct.sub buffer (i * block * t.info.sector_size) (block * t.info.sector_size)
    done;
    (* treat the slots as a circular buffer *)
    let producer_idx = ref 0 in
    let consumer_idx = ref 0 in
    let c = Lwt_condition.create () in

    let rec reader sector =
      if t.disconnected || sector = t.info.size_sectors then begin
        return (`Ok ())
      end else begin
        if !producer_idx - !consumer_idx >= nr_slots then begin
          Lwt_condition.wait c
          >>= fun () ->
          reader sector
        end else begin
          Region_lock.extend_right t.lock Int64.(add sector (of_int block))
          >>= fun () ->
          Primary.read t.primary Int64.(mul sector (of_int t.primary_block_size)) [ slots.(!producer_idx mod nr_slots) ]
          >>= function
          | `Error e ->
            t.disconnected <- true;
            Lwt_condition.signal c ();
            return (`Error e)
          | `Ok () ->
            incr producer_idx;
            Lwt_condition.signal c ();
            reader Int64.(add sector (of_int block))
        end
      end in
    let rec writer sector =
      let percent_complete = Int64.(to_int (div (mul sector 100L) t.info.size_sectors)) in
      if percent_complete <> t.percent_complete
      then t.progress_cb (if percent_complete = 100 then `Complete else `Percent percent_complete);
      t.percent_complete <- percent_complete;
      if t.disconnected || sector = t.info.size_sectors then begin
        return (`Ok ())
      end else begin
        if !consumer_idx = !producer_idx then begin
          Lwt_condition.wait c
          >>= fun () ->
          writer sector
        end else begin
          Secondary.write t.secondary Int64.(mul sector (of_int t.secondary_block_size)) [ slots.(!consumer_idx mod nr_slots) ]
          >>= function
          | `Error e ->
            t.disconnected <- true;
            Lwt_condition.signal c ();
            return (`Error e)
          | `Ok () ->
            incr consumer_idx;
            Region_lock.release_left t.lock Int64.(add sector (of_int block))
            >>= fun () ->
            Lwt_condition.signal c ();
            writer Int64.(add sector (of_int block))
        end
      end in
    let read_t = reader 0L in
    let write_t = writer 0L in
    read_t >>= fun read_result ->
    write_t >>= fun write_result ->
    ( match read_result, write_result with
      | `Ok (), `Ok () ->
        Lwt.wakeup u (`Ok ())
      | `Error e, `Ok () ->
        Lwt.wakeup u (`Error e)
      | `Ok (), `Error e ->
        Lwt.wakeup u (`Error e)
      | `Error e, `Error ei ->
        Lwt.wakeup u (`Error e) );
    return ()

  type id = unit

  let get_info t = return t.info

  let connect ?(progress_cb = fun _ -> ()) primary secondary =
    Primary.get_info primary
    >>= fun primary_info ->
    Secondary.get_info secondary
    >>= fun secondary_info ->

    let sector_size = max primary_info.Primary.sector_size secondary_info.Secondary.sector_size in
    (* We need our chosen sector_size to be an integer multiple of
       both primary and secondary sector sizes. This should be the
       very common case e.g. 4096 and 512; 512 and 1 *)
    let primary_block_size = sector_size / primary_info.Primary.sector_size in
    let secondary_block_size = sector_size / secondary_info.Secondary.sector_size in
    let primary_bytes = Int64.(mul primary_info.Primary.size_sectors (of_int primary_info.Primary.sector_size)) in
    let secondary_bytes = Int64.(mul secondary_info.Secondary.size_sectors (of_int secondary_info.Secondary.sector_size)) in

    ( let open Nbd_result in
      ( if sector_size mod primary_info.Primary.sector_size <> 0
        || sector_size mod secondary_info.Secondary.sector_size <> 0
        then fail (`Unknown (Printf.sprintf "Incompatible sector sizes: either primary (%d) or secondary (%d) must be an integer multiple of the other" primary_info.Primary.sector_size secondary_info.Secondary.sector_size))
        else return ()
      ) >>= fun () ->
      ( if primary_bytes <> secondary_bytes
        then fail (`Unknown (Printf.sprintf "Incompatible overall sizes: primary (%Ld bytes) and secondary (%Ld bytes) must be the same size" primary_bytes secondary_bytes))
        else return ()
      ) >>= fun () ->
      ( if not secondary_info.Secondary.read_write
        then fail (`Unknown "Cannot mirror to a read-only secondary device")
        else return ()
      )
    ) |> Lwt.return
    >>= function
    | `Error e -> return (`Error e)
    | `Ok () ->
      let disconnected = false in
      let read_write = primary_info.Primary.read_write in
      let size_sectors = Int64.(div primary_bytes (of_int sector_size)) in
      let info = { read_write; sector_size; size_sectors } in
      let lock = Region_lock.make () in
      let result, u = Lwt.task () in
      let percent_complete = 0 in
      let t = { progress_cb; primary; secondary; primary_block_size; secondary_block_size;
                info; lock; result; percent_complete; disconnected } in
      let (_: unit Lwt.t) = start_copy t u in
      return (`Ok t)

  let read t ofs bufs =
    Primary.read t.primary ofs bufs

  let write t ofs bufs =
    let total_length_bytes = List.(fold_left (+) 0 (map Cstruct.len bufs)) in
    let length = total_length_bytes / t.info.sector_size in
    let primary_ofs = Int64.(mul ofs (of_int t.primary_block_size)) in
    let secondary_ofs = Int64.(mul ofs (of_int t.secondary_block_size)) in
    Region_lock.with_lock t.lock ofs length
      (fun () ->
         Primary.write t.primary primary_ofs bufs
         >>= function
         | `Error e -> return (`Error e)
         | `Ok () ->
           Secondary.write t.secondary secondary_ofs bufs
      )

  let disconnect t =
    t.disconnected <- true;
    t.result
    >>= fun _ ->
    return ()
end
