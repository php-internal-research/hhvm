(*
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

(**
    +---------------------------------+
    | Let's talk about naming tables! |
    +---------------------------------+

    Every typechecker or compiler that's more complicated than a toy project needs some way to look
    up the location of a given symbol, especially one that operates at the same scale as Hack and
    double especially as Hack moves towards generating data lazily on demand instead of generating
    all of the data up front during strictly defined typechecking phases. In Hack, the data
    structures that map from symbols to filenames and from filenames to symbol names are referred to
    as the "naming table," with the "forward naming table" mapping from filenames to symbol names
    and the "reverse naming table" mapping from symbol names to file names. We store the forward
    naming table as a standard OCaml map since we only read and write it from the main process, and
    we store the reverse naming table in shared memory since we want to allow rapid reads and writes
    from worker processes.

    So, to recap:
      - Forward naming table: OCaml map, maps filename -> symbols in file
      - Reverse naming table: shared memory, maps symbol name to filename it's defined in

    Seems simple enough, right? Unfortunately, this is where the real world and all of its attendant
    complexity comes in. The naming table (forward + reverse) is big. And not only is it big, its
    size is on the order of O(repo). This conflicts with our goal of making Hack use a flat amount
    of memory regardless of the amount of code we're actually typechecking, so it needs to go. In
    this case, we've chosen to use our existing saved state infrastructure and dump the naming
    table to a SQLite file which we can use to serve queries without having to store anything in
    memory other than just the differences between what's in the saved state and what's on disk.

    Right now, only the reverse naming table supports falling back to SQLite, so let's go through
    each operation that the reverse naming table supports and cover how it handles falling back to
    SQLite.


    +---------------------------------+
    | Reverse naming table operations |
    +---------------------------------+

    The reverse naming table supports three operations: [put], [get], and [delete]. [Put] is pretty
    simple, conceptually, but there's some trickiness with [delete] that would benefit from being
    covered in more detail, and that trickiness bleeds into how [get] works as well. One important
    consideration is that *the SQLite database is read-only.* The general idea of these operations
    is that shared memory stores only entries that have changed.

    PUT:
    [Put] is simple. Since the SQLite database is read-only and we use shared memory for storing any
    changes, we just put the value in shared memory.

                        +------------------+    +------------+
                        |                  |    |            |
                        |   Naming Heap    |    |   SQLite   |
                        |                  |    |            |
    [put key value] -----> [put key value] |    |            |
                        |                  |    |            |
                        +------------------+    +------------+

    DELETE:
    We're going to cover [delete] next because it's the only reason that [get] has any complexity
    beyond "look for the value in shared memory and if it's not there look for it in SQLite." At
    first glance, [delete] doesn't seem too difficult. Just delete the entry from shared memory,
    right? Well, that's fine... unless that key also exists in SQLite. If the value is in SQLite,
    then all that deleting it from shared memory does is make us start returning the stored SQLite
    value! This is bad, because if we just deleted a key of course we want [get] operations for it
    to return [None]. But okay, we can work around that. Instead of storing direct values in shared
    memory, we'll store an enum of [[Added of 'a | Deleted]]. Easy peasy!

    ...except what do we do if we want to delete a value in the main process, then add it again in a
    worker process? That would require changing a key's value in shared memory, which is something
    that we don't support due to data integrity concerns with multiple writers and readers. We could
    remove and re-add, except removal can only be done by master because of the same integrity
    concerns. So master would somehow need to know which entries will be added and prematurely
    remove the [Deleted] sentinel from them. This is difficult enough as to be effectively
    impossible.

    So what we're left needing is some way to delete values which can be undone by child processes,
    which means that undeleting a value needs to consist only of [add] operations to shared memory,
    and have no dependency on [remove]. Enter: the blocked entries heap.

    For each of the reverse naming table heaps (types, functions, and constants) we also create a
    heap that only stores values of a single-case enum: [Blocked]. The crucial difference between
    [Blocked] and [[Added of 'a | Deleted]] is that *we only check for [Blocked] if the value is
    not in the shared memory naming heap.* This means that we can effectively undelete an entry by
    using an only an [add] operation.  Exactly what we need! Thus, [delete] becomes:

                        +-----------------+    +---------------------+    +------------+
                        |                 |    |                     |    |            |
                        |   Naming Heap   |    |   Blocked Entries   |    |   SQLite   |
                        |                 |    |                     |    |            |
    [delete key] --+-----> [delete key]   |    |                     |    |            |
                   |    |                 |    |                     |    |            |
                   +----------------------------> [add key Blocked]  |    |            |
                        |                 |    |                     |    |            |
                        +-----------------+    +---------------------+    +------------+

    GET:
    Wow, what a ride, huh? Now that we know how to add and remove entries, let's make this actually
    useful and talk about how to read them! The general idea is that we first check to see if the
    value is in the shared memory naming heap. If so, we can return that immediately. If it's not
    in the naming heap, then we check to see if it's blocked. If it is, we immediately return
    [None]. If it's not in the naming heap, and it's not in the blocked entries, then and only then
    do we read the value from SQLite:

                        +-----------------+    +---------------------+    +------------------+
                        |                 |    |                     |    |                  |
                        |   Naming Heap   |    |   Blocked Entries   |    |      SQLite      |
                        |                 |    |                     |    |                  |
    [get key] -----------> [get key] is:  |    |                     |    |                  |
    [Some value] <---------- [Some value] |    |                     |    |                  |
                        |    [None] -------+   |                     |    |                  |
                        |                 | \  |                     |    |                  |
                        |                 |  +--> [get key] is:      |    |                  |
    [None] <--------------------------------------- [Some Blocked]   |    |                  |
                        |                 |    |    [None] -----------+   |                  |
                        |                 |    |                     | \  |                  |
                        |                 |    |                     |  +--> [get key] is:   |
    [Some value] <------------------------------------------------------------ [Some value]  |
    [None] <------------------------------------------------------------------ [None]        |
                        |                 |    |                     |    |                  |
                        +-----------------+    +---------------------+    +------------------+

    And we're done! I hope this was easy to understand and as fun to read as it was to write :)

    MINUTIAE:
    Q: When do we delete entries from the Blocked Entries heaps?
    A: Never! Once an entry has been removed at least once we never want to retrieve the SQLite
       version for the rest of the program execution.

    Q: Won't we just end up with a heap full of [Blocked] entries now?
    A: Not really. We only have to do deletions once to remove entries for dirty files, and after
       that it's not a concern. Plus [Blocked] entries are incredibly small in shared memory
       (although they do still occupy a hash slot).
*)

(* Changes since baseline can be None if there was no baseline to begin with.
  The scenario where we apply changes since baseline instead of relying on
  the packaged local changes in the LOCAL_CHANGES table is this:
    1) Load the naming table baseline (may include local changes if it was
      incrementally updated at some point - not currently done in practice,
      but possible and likely to happen in the future)
    2) Load the changes since baseline that include naming changes processed
      at another time (perhaps, on another host)
  In the scenario where the naming table is saved to SQLite from an Unbacked
  naming table, there is no baseline to speak of
  *)
type changes_since_baseline = Naming_sqlite.local_changes option

type t =
  | Unbacked of FileInfo.t Relative_path.Map.t
  | Backed of Naming_sqlite.local_changes
[@@deriving show]

type fast = FileInfo.names Relative_path.Map.t

type saved_state_info = FileInfo.saved Relative_path.Map.t

(*****************************************************************************)
(* Forward naming table functions *)
(*****************************************************************************)

let empty = Unbacked Relative_path.Map.empty

let filter a ~f =
  match a with
  | Unbacked a -> Unbacked (Relative_path.Map.filter a f)
  | Backed local_changes ->
    let file_deltas = local_changes.Naming_sqlite.file_deltas in
    Backed
      {
        local_changes with
        Naming_sqlite.file_deltas =
          Naming_sqlite.fold
            ~init:file_deltas
            ~f:
              begin
                fun path fi acc ->
                if f path fi then
                  acc
                else
                  Relative_path.Map.add
                    acc
                    ~key:path
                    ~data:Naming_sqlite.Deleted
              end
            ~file_deltas;
      }

let fold a ~init ~f =
  match a with
  | Unbacked a -> Relative_path.Map.fold a ~init ~f
  | Backed local_changes ->
    Naming_sqlite.fold
      ~init
      ~f
      ~file_deltas:local_changes.Naming_sqlite.file_deltas

let get_files a =
  match a with
  | Unbacked a -> Relative_path.Map.keys a
  | Backed local_changes ->
    (* Reverse at the end to preserve ascending sort order. *)
    Naming_sqlite.fold
      ~init:[]
      ~f:(fun path _ acc -> path :: acc)
      ~file_deltas:local_changes.Naming_sqlite.file_deltas
    |> List.rev

let get_files_changed_since_baseline
    (changes_since_baseline : changes_since_baseline) : Relative_path.t list =
  match changes_since_baseline with
  | Some changes_since_baseline ->
    Relative_path.Map.keys changes_since_baseline.Naming_sqlite.file_deltas
  | None -> []

let get_file_info a key =
  match a with
  | Unbacked a -> Relative_path.Map.find_opt a key
  | Backed local_changes ->
    (match
       Relative_path.Map.find_opt local_changes.Naming_sqlite.file_deltas key
     with
    | Some (Naming_sqlite.Modified fi) -> Some fi
    | Some Naming_sqlite.Deleted -> None
    | None -> Naming_sqlite.get_file_info key)

let get_file_info_unsafe a key =
  Core_kernel.Option.value_exn (get_file_info a key)

let has_file a key =
  match get_file_info a key with
  | Some _ -> true
  | None -> false

let iter a ~f =
  match a with
  | Unbacked a -> Relative_path.Map.iter a ~f
  | Backed local_changes ->
    Naming_sqlite.fold
      ~init:()
      ~f:(fun path fi () -> f path fi)
      ~file_deltas:local_changes.Naming_sqlite.file_deltas

let remove a key =
  match a with
  | Unbacked a -> Unbacked (Relative_path.Map.remove a key)
  | Backed local_changes ->
    Backed
      {
        local_changes with
        Naming_sqlite.file_deltas =
          Relative_path.Map.add
            local_changes.Naming_sqlite.file_deltas
            ~key
            ~data:Naming_sqlite.Deleted;
      }

let update a key data =
  match a with
  | Unbacked a -> Unbacked (Relative_path.Map.add a ~key ~data)
  | Backed local_changes ->
    Backed
      {
        local_changes with
        Naming_sqlite.file_deltas =
          Relative_path.Map.add
            local_changes.Naming_sqlite.file_deltas
            ~key
            ~data:(Naming_sqlite.Modified data);
      }

let update_many a updates =
  match a with
  | Unbacked a ->
    (* Reverse the order because union always takes the first value. *)
    Unbacked (Relative_path.Map.union updates a)
  | Backed local_changes ->
    let local_updates =
      Relative_path.Map.map updates ~f:(fun data -> Naming_sqlite.Modified data)
    in
    Backed
      {
        local_changes with
        Naming_sqlite.file_deltas =
          Relative_path.Map.union
            local_updates
            local_changes.Naming_sqlite.file_deltas;
      }

let combine a b =
  match b with
  | Unbacked b -> update_many a b
  | _ ->
    failwith
      "SQLite-backed naming tables cannot be the second argument to combine."

(**
  This function saves the local changes structure as a binary blob.
  Local changes represents the (forward) naming table changes since
  the SQLite naming table baseline. Therefore, this function is most meaningful
  when the naming table is backed by SQLite. If the naming table is NOT backed
  by SQLite, meaning that it was computed from scratch by parsing the whole
  repo, then this baseline-to-current difference is an empty set.
  The resulting snapshot can be applied when loading a SQLite naming table.
 *)
let save_changes_since_baseline naming_table ~destination_path =
  let snapshot =
    match naming_table with
    | Unbacked _ -> None
    | Backed local_changes -> Some local_changes
  in
  let contents = Marshal.to_string snapshot [Marshal.No_sharing] in
  Disk.write_file ~file:destination_path ~contents

let save naming_table db_name =
  match naming_table with
  | Unbacked naming_table ->
    let t = Unix.gettimeofday () in
    (* Ideally, we would have a commit hash, which would result in the same
      content version given the same version of source files. However,
      using a unique version every time we save the naming table from scratch
      is good enough to enable us to check that the local changes diff
      provided as an argument to load_from_sqlite_with_changes_since_baseline
      is compatible with the underlying SQLite table. *)
    let base_content_version =
      Printf.sprintf "%d-%s" (int_of_float t) (Random_id.short_string ())
    in
    let save_result =
      Naming_sqlite.save_file_infos db_name naming_table ~base_content_version
    in
    let (_ : float) =
      Hh_logger.log_duration
        (Printf.sprintf
           "Inserted %d files and %d symbols"
           save_result.Naming_sqlite.files_added
           save_result.Naming_sqlite.symbols_added)
        t
    in
    save_result
  | Backed local_changes ->
    let t = Unix.gettimeofday () in
    let old_path = Naming_sqlite.get_db_path () in
    (* Don't overwrite. *)
    FileUtil.cp
      ~force:(FileUtil.Ask (fun _ -> false))
      [Core_kernel.Option.value_exn (Naming_sqlite.get_db_path ())]
      db_name;
    Naming_sqlite.set_db_path (Some db_name);
    Naming_sqlite.update_file_infos db_name local_changes;
    let (_ : float) =
      Hh_logger.log_duration
        (Printf.sprintf
           "Updated a blob with %d entries"
           (Relative_path.Map.cardinal local_changes.Naming_sqlite.file_deltas))
        t
    in
    Naming_sqlite.set_db_path old_path;
    { Naming_sqlite.empty_save_result with Naming_sqlite.files_added = 1 }

(*****************************************************************************)
(* Conversion functions *)
(*****************************************************************************)

let from_saved saved =
  Hh_logger.log "Loading naming table from marshalled blob...";
  let t = Unix.gettimeofday () in
  let naming_table =
    Unbacked
      (Relative_path.Map.fold
         saved
         ~init:Relative_path.Map.empty
         ~f:(fun fn saved acc ->
           let file_info = FileInfo.from_saved fn saved in
           Relative_path.Map.add acc fn file_info))
  in
  let _t = Hh_logger.log_duration "Loaded naming table from blob" t in
  naming_table

let to_saved a =
  match a with
  | Unbacked a -> Relative_path.Map.map a FileInfo.to_saved
  | Backed _ ->
    fold a ~init:Relative_path.Map.empty ~f:(fun path fi acc ->
        Relative_path.Map.add acc ~key:path ~data:(FileInfo.to_saved fi))

let to_fast a =
  match a with
  | Unbacked a -> Relative_path.Map.map a FileInfo.simplify
  | Backed _ ->
    fold a ~init:Relative_path.Map.empty ~f:(fun path fi acc ->
        Relative_path.Map.add acc ~key:path ~data:(FileInfo.simplify fi))

let saved_to_fast saved = Relative_path.Map.map saved FileInfo.saved_to_names

(*****************************************************************************)
(* Forward naming table creation functions *)
(*****************************************************************************)

let create a = Unbacked a

let update_reverse_entries file_deltas =
  Relative_path.Map.iter file_deltas ~f:(fun path delta ->
      begin
        match Naming_sqlite.get_file_info path with
        | Some fi ->
          Naming_provider.remove_type_batch
            (fi.FileInfo.classes |> List.map snd |> SSet.of_list);
          Naming_provider.remove_type_batch
            (fi.FileInfo.typedefs |> List.map snd |> SSet.of_list);
          Naming_provider.remove_fun_batch
            (fi.FileInfo.funs |> List.map snd |> SSet.of_list);
          Naming_provider.remove_const_batch
            (fi.FileInfo.consts |> List.map snd |> SSet.of_list)
        | None -> ()
      end;
      match delta with
      | Naming_sqlite.Modified fi ->
        List.iter
          (fun (pos, name) -> Naming_provider.add_class name pos)
          fi.FileInfo.classes;
        List.iter
          (fun (pos, name) -> Naming_provider.add_record_def name pos)
          fi.FileInfo.record_defs;
        List.iter
          (fun (pos, name) -> Naming_provider.add_typedef name pos)
          fi.FileInfo.typedefs;
        List.iter
          (fun (pos, name) -> Naming_provider.add_fun name pos)
          fi.FileInfo.funs;
        List.iter
          (fun (pos, name) -> Naming_provider.add_const name pos)
          fi.FileInfo.consts
      | Naming_sqlite.Deleted -> ())

let choose_local_changes ~local_changes ~custom_local_changes =
  match custom_local_changes with
  | None -> local_changes
  | Some custom_local_changes ->
    if
      custom_local_changes.Naming_sqlite.base_content_version
      = local_changes.Naming_sqlite.base_content_version
    then
      custom_local_changes
    else
      failwith
        (Printf.sprintf
           "%s\nSQLite content version: %s\nLocal changes content version: %s"
           "Incompatible local changes diff supplied."
           local_changes.Naming_sqlite.base_content_version
           custom_local_changes.Naming_sqlite.base_content_version)

(**
  Loads the naming table from a SQLite database. The optional custom local
  changes represents the naming table changes that occurred since the original
  SQLite database was created.
  To recap, the SQLite-based naming table, once loaded, is not mutated. All the
  forward naming table changes are kept in an in-memory map. When we save an
  update to a naming table that is backed by SQLite, we store the changes
  since the baseline as a blob is a separate table and we rehydrate those
  changes into an in-memory map when we load the updated naming table later.
  The custom local changes is an alternative to the changes serialized as a
  blob into the SQLite table. This enables scenarios that require repeatedly
  loading the same base SQLite naming table with different versions of
  the local changes.
 *)
let load_from_sqlite_for_type_checking
    ~(should_update_reverse_entries : bool)
    ~(custom_local_changes : Naming_sqlite.local_changes option)
    (db_path : string) : t =
  Hh_logger.log "Loading naming table from SQLite...";
  let t = Unix.gettimeofday () in
  Naming_sqlite.set_db_path (Some db_path);
  let local_changes =
    choose_local_changes
      ~local_changes:(Naming_sqlite.get_local_changes ())
      ~custom_local_changes
  in
  let t = Hh_logger.log_duration "Loaded local naming table changes" t in
  if should_update_reverse_entries then begin
    update_reverse_entries local_changes.Naming_sqlite.file_deltas;
    let _t = Hh_logger.log_duration "Updated reverse naming table entries" t in
    ()
  end;
  Backed local_changes

let load_from_sqlite_with_changes_since_baseline
    (changes_since_baseline : Naming_sqlite.local_changes option)
    (db_path : string) : t =
  load_from_sqlite_for_type_checking
    ~should_update_reverse_entries:true
    ~custom_local_changes:changes_since_baseline
    db_path

let load_from_sqlite_for_batch_update (db_path : string) : t =
  load_from_sqlite_for_type_checking
    ~should_update_reverse_entries:false
    ~custom_local_changes:None
    db_path

let load_from_sqlite (db_path : string) : t =
  load_from_sqlite_for_type_checking
    ~should_update_reverse_entries:true
    ~custom_local_changes:None
    db_path

let get_reverse_naming_fallback_path () : string option =
  Naming_sqlite.get_db_path ()

let get_forward_naming_fallback_path a : string option =
  match a with
  | Unbacked _ -> None
  | Backed _ -> Naming_sqlite.get_db_path ()

(*****************************************************************************)
(* Testing functions *)
(*****************************************************************************)

let assert_is_backed a backed =
  match a with
  | Unbacked _ -> assert (not backed)
  | Backed _ -> assert backed
