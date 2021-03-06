(*
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

open Hh_prelude

let get_type_id_filename x expected_kind =
  Counters.count_decl_accessor @@ fun () ->
  match Naming_provider.get_type_path_and_kind x with
  | Some (fn, kind) when Naming_types.equal_kind_of_type kind expected_kind ->
    Some fn
  | _ -> None

let get_class = Typing_classes_heap.Classes.get

let get_fun ctx x =
  Counters.count_decl_accessor @@ fun () ->
  match Typing_heap.Funs.get x with
  | Some c -> Some c
  | None ->
    (match Naming_provider.get_fun_path x with
    | Some filename ->
      let ft =
        Errors.run_in_decl_mode filename (fun () ->
            Decl.declare_fun_in_file ctx filename x)
      in
      Some ft
    | None -> None)

let get_gconst ctx cst_name =
  Counters.count_decl_accessor @@ fun () ->
  match Typing_heap.GConsts.get cst_name with
  | Some c -> Some c
  | None ->
    (match Naming_provider.get_const_path cst_name with
    | Some filename ->
      let gconst =
        Errors.run_in_decl_mode filename (fun () ->
            Decl.declare_const_in_file ctx filename cst_name)
      in
      Some gconst
    | None -> None)

let get_record_def ctx x =
  Counters.count_decl_accessor @@ fun () ->
  match Typing_heap.RecordDefs.get x with
  | Some c -> Some c
  | None ->
    (match get_type_id_filename x Naming_types.TRecordDef with
    | Some filename ->
      let tdecl =
        Errors.run_in_decl_mode filename (fun () ->
            Decl.declare_record_def_in_file ctx filename x)
      in
      Some tdecl
    | None -> None)

let get_typedef ctx x =
  Counters.count_decl_accessor @@ fun () ->
  match Typing_heap.Typedefs.get x with
  | Some c -> Some c
  | None ->
    (match get_type_id_filename x Naming_types.TTypedef with
    | Some filename ->
      let tdecl =
        Errors.run_in_decl_mode filename (fun () ->
            Decl.declare_typedef_in_file ctx filename x)
      in
      Some tdecl
    | None -> None)
