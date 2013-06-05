(*
 * Copyright (c) 2013 David Sheets <sheets@alum.mit.edu>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 *)

open Sexplib.Std
open Repo
open Lwt

module StrSet = Set.Make(String)

type pull_part = Base | Head
exception WTFGitHub of string
exception GitError of Result.output
exception NonPackageUpdate of string list

let branch_of_pull part pull = Github_t.(
  let pull_id = pull.pull_number in
  let ref_base = "refs/pull/"^(string_of_int pull_id)^"/" in
  let base = match pull.pull_base.branch_repo with
    | None -> raise (WTFGitHub
                       (Printf.sprintf "pull %d lacks a base repo" pull_id))
    | Some repo -> repo
  in
  let repo_url = URL (Uri.of_string base.repo_clone_url) in
  match part with
    | Head -> let gitref = ref_base^"head" in Repo.({
      repo={ url=Uri.of_string ""; repo_url };
      reference=Repo.Commit (gitref, pull.pull_head.branch_sha);
      label=base.repo_full_name^":"^gitref;
    })
    | Base -> let gitref = ref_base^"base" in Repo.({
      repo={ url=Uri.of_string ""; repo_url };
      reference=Repo.Commit (gitref, pull.pull_base.branch_sha);
      label=base.repo_full_name^":"^gitref;
    })
)

let diff_of_pull pull = [
  branch_of_pull Head pull;
  branch_of_pull Base pull;
]

let pkg_change_re component = Re.(compile (seq [
  str "packages/"; group (rep1 (non_greedy any)); component
]))

let pkg_descr = Re.(str "/descr")
let pkg_descr_re = pkg_change_re pkg_descr
let pkg_semantic = Re.(alt [
  str "/opam";
  str "/url";
  seq [str "/files/"; non_greedy (rep1 any); str ".install"; eos];
])
let pkg_sem_re = pkg_change_re pkg_semantic

(* TODO: log inference *)
let try_infer_packages base_ref_str head_ref_str merge_dir =
  let mod_files = ref [] in
  try begin
    run_command ~cwd:merge_dir
      [ "git" ; "diff" ; "--name-only" ; base_ref_str ; head_ref_str ]
    >>= fun { r_stdout } ->
    mod_files := List.filter (fun filename ->
      not (Re.execp pkg_descr_re filename)
    ) Re_str.(split (regexp_string "\n") r_stdout);
    let packages = List.fold_left (fun set filename ->
      StrSet.add Re.(get (exec pkg_sem_re filename) 1) set
    ) StrSet.empty !mod_files in
    return (StrSet.elements packages)
  end with
    | Not_found ->
        let non_package_updates = List.filter (fun filename ->
          not (Re.execp pkg_sem_re filename)
        ) !mod_files in
        fail (NonPackageUpdate non_package_updates)

(* TODO: clean-up fs *)
let packages_of_diff prefix work_dir diff =
  let prefix = prefix^"-merge" in
  let tmp_name = make_temp_dir ~root_dir:work_dir ~prefix in
  let merge_name = Filename.concat tmp_name "opam-repository" in
  let head = (List.hd diff).reference in
  let base = (List.hd (List.rev diff)).reference in
  Unix.mkdir merge_name 0o700;
  try_collapse ~dir:merge_name diff
  >>= try_infer_packages (string_of_reference head) (string_of_reference base)
