open Sexplib.Std
open Lwt

module Uri = struct
  include Uri
  let t_of_sexp sexp =
    of_string (Sexplib.Std.string_of_sexp sexp)
  let sexp_of_t uri = Sexplib.Std.sexp_of_string (to_string uri)
end

type git =
  | SSH of Uri.t * Uri.t
  | URL of Uri.t
with sexp

type 'a t = {
  url : Uri.t;
  repo_url : 'a;
} with sexp

type sha = string with sexp

type reference =
  | Ref of string
  | Commit of string * sha
  | Copy of string * reference
with sexp

type 'a branch = {
  repo : 'a t;
  label : string;
  reference : reference;
} with sexp

type diff = git branch list with sexp

type r = {
  r_cmd : string;
  r_args : string list;
  r_env : string array;
  r_cwd : string;
  r_duration : Time.duration;
  r_stdout : string;
  r_stderr : string;
}

exception ProcessError of Unix.process_status * r

let rec string_of_diff = function
  | [] -> ""
  | b::[] -> b.label
  | b::bs -> b.label^" onto "^(string_of_diff bs)

let string_of_git = function
  | SSH (host, path) -> (Uri.to_string host)^":"^(Uri.to_string path)
  | URL url -> Uri.to_string url

let in_dir dir fn =
  let cwd = Sys.getcwd () in
  let reset_cwd () = Unix.chdir cwd in
  Unix.chdir dir;
  catch
    (fun () ->
      let r = fn () in
      reset_cwd ();
      r)
    (fun exn ->
      reset_cwd ();
      fail exn)

let run_command ?(env=[||]) cmd_args =
  let cmd = List.hd cmd_args in
  let args = List.tl cmd_args in
  let cmd_args = Array.of_list cmd_args in
  let time = Time.now () in
  let cwd = Sys.getcwd () in
  let process = Lwt_process.open_process_full ~env ("", cmd_args) in
  process#status
  >>= fun status ->
  Lwt_io.read process#stdout
  >>= fun r_stdout ->
  Lwt_io.read process#stderr
  >>= fun r_stderr ->
  let r_duration = Time.(elapsed (now ()) time) in
  let r = {
    r_cmd = cmd;
    r_args = args;
    r_env = env;
    r_cwd = cwd;
    r_duration;
    r_stdout;
    r_stderr;
  } in match status with
    | Unix.WEXITED 0 -> return r
    | _ -> fail (ProcessError (status,r))

let run_commands ?(env=[||]) = Lwt_list.map_s (run_command ~env)

let rec update_ref_cmd = function
  | Ref r -> r, []
  | Commit (r, sha) -> r, [[ "git" ; "update-ref" ; r ; sha ]]
  | Copy (a, b) ->
      let b, cmd = update_ref_cmd b in
      a, cmd@[[ "git" ; "update-ref" ; a ; b ]]

let update_refs ~dir refs =
  in_dir dir (fun () ->
    run_commands (List.fold_left (fun cmds r ->
      (snd (update_ref_cmd r))@cmds
    ) [] refs))
  >>= fun _ -> return dir

let clone_repo ~dir ~commit =
  let url = string_of_git commit.repo.repo_url in
  let git_ref, ref_cmd = update_ref_cmd commit.reference in
  in_dir dir (fun () -> run_commands ([
    [ "git" ; "clone" ; url ; "." ];
  ]@ref_cmd@[
    [ "git" ; "checkout" ; git_ref ];
  ]))
  >>= fun _ ->
  Printf.eprintf "OCAMLOT repo clone %s\n%!" commit.label;
  return dir

let make_temp_dir ~root_dir ~prefix =
  let tmp_name = Util.make_fresh_dir ~root_dir
    ("ocamlot."^prefix^"."^Time.(date_to_string (now ()))^".") in
  Printf.eprintf "OCAMLOT temp_dir %s made\n%!" tmp_name;
  tmp_name

let fetch_refspec ~dir ~url ~refspec =
  in_dir dir (fun () -> run_command [
    "git" ; "fetch" ; string_of_git url ; refspec ;
  ])
  >>= fun _ ->
  Printf.eprintf "OCAMLOT fetch refspec %s into %s\n%!"
    refspec dir;
  return dir

let push_refspec ~dir ~url ~refspec =
  in_dir dir (fun () -> run_command [
    "git" ; "push" ; string_of_git url ; refspec ;
  ])
  >>= fun _ ->
  Printf.eprintf "OCAMLOT push refspec %s onto %s\n%!"
    refspec (string_of_git url);
  return dir

let try_merge ~dir ~base ~head =
  let refspec = match head.reference with
    | Ref h | Commit (h,_) | Copy (h,_) -> h^":"^h in
  fetch_refspec ~dir ~url:head.repo.repo_url ~refspec
  >>= fun dir ->
  (* TODO: update-ref ? *)
  in_dir dir (fun () -> run_command [
    "git" ; "merge" ; "--no-edit" ;
    (match head.reference with Ref h | Commit (h,_) | Copy (h,_) -> h);
  ])
  >>= fun _ ->
  Printf.eprintf "OCAMLOT repo merge %s onto %s\n%!"
    head.label base.label;
  return dir

let try_collapse ~dir = function
  | [] -> return dir
  | bl -> begin
    let diffl = List.rev bl in
    let base = List.hd diffl in
    let rec merge diffl dir = match diffl with
      | [] -> return dir
      | head::bs -> try_merge ~dir ~base ~head >>= (merge bs)
    in
    clone_repo ~dir ~commit:base
    >>= (merge (List.tl diffl))
  end
