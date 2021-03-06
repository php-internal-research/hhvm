(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)
open Core_kernel

module Compute_tast = struct
  type t = {
    tast: Tast.program;
    telemetry: Telemetry.t;
  }
end

module Compute_tast_and_errors = struct
  type t = {
    tast: Tast.program;
    errors: Errors.t;
    telemetry: Telemetry.t;
  }
end

let ctx_from_server_env (env : ServerEnv.env) : Provider_context.t =
  {
    Provider_context.popt = env.ServerEnv.popt;
    tcopt = env.ServerEnv.tcopt;
    (* TODO: backend should be stored in [env]. *)
    backend = Provider_backend.get ();
    entries = Relative_path.Map.empty;
  }

let make_entry
    ~(ctx : Provider_context.t) ~(path : Relative_path.t) ~(contents : string) :
    Provider_context.t * Provider_context.entry =
  let entry =
    {
      Provider_context.path;
      contents;
      source_text = None;
      parser_return = None;
      ast_errors = None;
      cst = None;
      tast = None;
      tast_errors = None;
      symbols = None;
    }
  in
  let ctx =
    {
      ctx with
      Provider_context.entries =
        Relative_path.Map.add ctx.Provider_context.entries path entry;
    }
  in
  (ctx, entry)

let add_entry_from_file_input
    ~(ctx : Provider_context.t)
    ~(path : Relative_path.t)
    ~(file_input : ServerCommandTypes.file_input) :
    Provider_context.t * Provider_context.entry =
  let contents =
    match file_input with
    | ServerCommandTypes.FileName path -> Sys_utils.cat path
    | ServerCommandTypes.FileContent contents -> contents
  in
  make_entry ~ctx ~path ~contents

let add_entry ~(ctx : Provider_context.t) ~(path : Relative_path.t) :
    Provider_context.t * Provider_context.entry =
  let contents = Sys_utils.cat (Relative_path.to_absolute path) in
  make_entry ~ctx ~path ~contents

let add_entry_from_file_contents
    ~(ctx : Provider_context.t) ~(path : Relative_path.t) ~(contents : string) :
    Provider_context.t * Provider_context.entry =
  make_entry ~ctx ~path ~contents

let find_entry ~(ctx : Provider_context.t) ~(path : Relative_path.t) :
    Provider_context.entry option =
  Relative_path.Map.find_opt ctx.Provider_context.entries path

let compute_source_text ~(entry : Provider_context.entry) :
    Full_fidelity_source_text.t =
  match entry with
  | { Provider_context.source_text = Some source_text; _ } -> source_text
  | _ ->
    let source_text =
      Full_fidelity_source_text.make
        entry.Provider_context.path
        entry.Provider_context.contents
    in
    entry.Provider_context.source_text <- Some source_text;
    source_text

(* Note that some callers may not actually need the AST errors. This could be
improved with a method similar to the TAST-and-errors generation, where the TAST
errors are not generated unless necessary. *)
let compute_parser_return_and_ast_errors
    ~(ctx : Provider_context.t) ~(entry : Provider_context.entry) :
    Parser_return.t * Errors.t =
  match entry with
  | {
   Provider_context.ast_errors = Some ast_errors;
   parser_return = Some parser_return;
   _;
  } ->
    (parser_return, ast_errors)
  | _ ->
    (* Not used yet, but we will eventually want to extract the parser options
  from the [Provider_context.t]. *)
    let (_ : Provider_context.t) = ctx in
    let source_text = compute_source_text entry in
    let (ast_errors, parser_return) =
      Errors.do_with_context
        entry.Provider_context.path
        Errors.Parsing
        (fun () ->
          Ast_provider.parse ctx ~full:true ~keep_errors:true ~source_text)
    in
    entry.Provider_context.ast_errors <- Some ast_errors;
    entry.Provider_context.parser_return <- Some parser_return;
    (parser_return, ast_errors)

let compute_ast ~(ctx : Provider_context.t) ~(entry : Provider_context.entry) :
    Nast.program =
  let ({ Parser_return.ast; _ }, _ast_errors) =
    compute_parser_return_and_ast_errors ~ctx ~entry
  in
  ast

let compute_comments
    ~(ctx : Provider_context.t) ~(entry : Provider_context.entry) :
    Parser_return.comments =
  let ({ Parser_return.comments; _ }, _ast_errors) =
    compute_parser_return_and_ast_errors ~ctx ~entry
  in
  comments

let compute_file_info
    ~(ctx : Provider_context.t) ~(entry : Provider_context.entry) : FileInfo.t =
  let ast = compute_ast ~ctx ~entry in
  let (funs, classes, record_defs, typedefs, consts) = Nast.get_defs ast in
  {
    FileInfo.empty_t with
    FileInfo.funs;
    classes;
    record_defs;
    typedefs;
    consts;
  }

let compute_cst ~(ctx : Provider_context.t) ~(entry : Provider_context.entry) :
    Provider_context.PositionedSyntaxTree.t =
  let _ = ctx in
  match entry.Provider_context.cst with
  | Some cst -> cst
  | None ->
    let source_text = compute_source_text ~entry in
    let cst = Provider_context.PositionedSyntaxTree.make source_text in
    entry.Provider_context.cst <- Some cst;
    cst

let respect_but_quarantine_unsaved_changes
    ~(ctx : Provider_context.t) ~(f : unit -> 'a) : 'a =
  let make_then_revert_local_changes f () =
    Utils.with_context
      ~enter:(fun () ->
        Provider_context.set_global_context_internal ctx;

        Errors.set_allow_errors_in_default_path true;
        SharedMem.allow_hashtable_writes_by_current_process false;

        Ast_provider.local_changes_push_stack ();
        Decl_provider.local_changes_push_stack ctx;
        File_provider.local_changes_push_stack ();
        Fixme_provider.local_changes_push_stack ();

        Ide_parser_cache.activate ();

        Naming_provider.push_local_changes ())
      ~exit:(fun () ->
        Errors.set_allow_errors_in_default_path false;
        SharedMem.allow_hashtable_writes_by_current_process true;

        Ast_provider.local_changes_pop_stack ();
        Decl_provider.local_changes_pop_stack ctx;
        File_provider.local_changes_pop_stack ();
        Fixme_provider.local_changes_pop_stack ();

        Ide_parser_cache.deactivate ();

        Naming_provider.pop_local_changes ();

        SharedMem.invalidate_caches ();

        Provider_context.unset_global_context_internal ())
      ~do_:f
  in
  let (_errors, result) =
    Errors.do_
    @@ make_then_revert_local_changes (fun () ->
           Relative_path.Map.iter
             ctx.Provider_context.entries
             ~f:(fun _path entry ->
               let ast = compute_ast ctx entry in
               let (funs, classes, record_defs, typedefs, consts) =
                 Nast.get_defs ast
               in
               (* Update the positions of the symbols present in the AST by redeclaring
        them. Note that this doesn't handle *removing* any entries from the
        naming table if they've disappeared since the last time we updated the
        naming table. *)
               let get_names ids = List.map ~f:snd ids |> SSet.of_list in
               Naming_global.remove_decls
                 ~funs:(get_names funs)
                 ~classes:(get_names classes)
                 ~record_defs:(get_names record_defs)
                 ~typedefs:(get_names typedefs)
                 ~consts:(get_names consts);
               Naming_global.make_env
                 ctx
                 ~funs
                 ~classes
                 ~record_defs
                 ~typedefs
                 ~consts);

           f ())
  in
  result

type _ compute_tast_mode =
  | Compute_tast_only : Compute_tast.t compute_tast_mode
  | Compute_tast_and_errors : Compute_tast_and_errors.t compute_tast_mode

let compute_tast_and_errors_unquarantined_internal
    (type a)
    ~(ctx : Provider_context.t)
    ~(entry : Provider_context.entry)
    ~(mode : a compute_tast_mode) : a =
  match
    (mode, entry.Provider_context.tast, entry.Provider_context.tast_errors)
  with
  | (Compute_tast_only, Some tast, _) ->
    { Compute_tast.tast; telemetry = Telemetry.create () }
  | (Compute_tast_and_errors, Some tast, Some tast_errors) ->
    let (_parser_return, ast_errors) =
      compute_parser_return_and_ast_errors ~ctx ~entry
    in
    let errors = Errors.merge ast_errors tast_errors in
    { Compute_tast_and_errors.tast; errors; telemetry = Telemetry.create () }
  | (mode, _, _) ->
    (* prepare logging *)
    Deferred_decl.reset ~enable:false ~threshold_opt:None;
    Provider_context.reset_telemetry ctx;
    let prev_telemetry =
      Telemetry.create () |> Provider_context.get_telemetry ctx
    in
    let prev_tally_state = Counters.reset ~enable:true in
    let t = Unix.gettimeofday () in

    (* do the work *)
    let ({ Parser_return.ast; _ }, ast_errors) =
      compute_parser_return_and_ast_errors ~ctx ~entry
    in
    let (nast_errors, nast) =
      Errors.do_with_context
        entry.Provider_context.path
        Errors.Naming
        (fun () -> Naming.program ctx ast)
    in
    let (tast_errors, tast) =
      let do_tast_checks =
        match mode with
        | Compute_tast_only -> false
        | Compute_tast_and_errors -> true
      in
      Errors.do_with_context
        entry.Provider_context.path
        Errors.Typing
        (fun () -> Typing_toplevel.nast_to_tast ~do_tast_checks ctx nast)
    in
    let tast_errors = Errors.merge nast_errors tast_errors in

    (* Logging... *)
    let telemetry = Counters.get_counters () in
    Counters.restore_state prev_tally_state;
    let telemetry =
      telemetry
      |> Provider_context.get_telemetry ctx
      |> Telemetry.float_
           ~key:"duration_decl_and_typecheck"
           ~value:(Unix.gettimeofday () -. t)
      |> Telemetry.object_ ~key:"prev" ~value:prev_telemetry
    in
    (* File size. *)
    let telemetry =
      Telemetry.int_
        telemetry
        ~key:"filesize"
        ~value:(String.length entry.Provider_context.contents)
    in

    Hh_logger.debug
      "compute_tast: %s\n%s"
      (Relative_path.suffix entry.Provider_context.path)
      (Telemetry.to_string telemetry);
    HackEventLogger.ProfileTypeCheck.compute_tast
      ~telemetry
      ~path:entry.Provider_context.path;

    (match mode with
    | Compute_tast_and_errors ->
      entry.Provider_context.tast <- Some tast;
      entry.Provider_context.tast_errors <- Some tast_errors;
      let errors = Errors.merge ast_errors tast_errors in
      { Compute_tast_and_errors.tast; errors; telemetry }
    | Compute_tast_only ->
      entry.Provider_context.tast <- Some tast;
      { Compute_tast.tast; telemetry })

let compute_tast_and_errors_unquarantined
    ~(ctx : Provider_context.t) ~(entry : Provider_context.entry) :
    Compute_tast_and_errors.t =
  compute_tast_and_errors_unquarantined_internal
    ~ctx
    ~entry
    ~mode:Compute_tast_and_errors

let compute_tast_unquarantined
    ~(ctx : Provider_context.t) ~(entry : Provider_context.entry) :
    Compute_tast.t =
  compute_tast_and_errors_unquarantined_internal
    ~ctx
    ~entry
    ~mode:Compute_tast_only

let compute_tast_and_errors_quarantined
    ~(ctx : Provider_context.t) ~(entry : Provider_context.entry) :
    Compute_tast_and_errors.t =
  (* If results have already been memoized, don't bother quarantining anything *)
  match (entry.Provider_context.tast, entry.Provider_context.tast_errors) with
  | (Some tast, Some tast_errors) ->
    let (_parser_return, ast_errors) =
      compute_parser_return_and_ast_errors ~ctx ~entry
    in
    let errors = Errors.merge ast_errors tast_errors in
    { Compute_tast_and_errors.tast; errors; telemetry = Telemetry.create () }
  (* Okay, we don't have memoized results, let's ensure we are quarantined before computing *)
  | _ ->
    let f () = compute_tast_and_errors_unquarantined ~ctx ~entry in
    (* If global context is not set, set it and proceed *)
    (match Provider_context.get_global_context () with
    | None -> respect_but_quarantine_unsaved_changes ~ctx ~f
    | Some _ -> f ())

let compute_tast_quarantined
    ~(ctx : Provider_context.t) ~(entry : Provider_context.entry) :
    Compute_tast.t =
  (* If results have already been memoized, don't bother quarantining anything *)
  match entry.Provider_context.tast with
  | Some tast -> { Compute_tast.tast; telemetry = Telemetry.create () }
  (* Okay, we don't have memoized results, let's ensure we are quarantined before computing *)
  | None ->
    let f () =
      compute_tast_and_errors_unquarantined_internal
        ~ctx
        ~entry
        ~mode:Compute_tast_only
    in
    (* If global context is not set, set it and proceed *)
    (match Provider_context.get_global_context () with
    | None -> respect_but_quarantine_unsaved_changes ~ctx ~f
    | Some _ -> f ())
