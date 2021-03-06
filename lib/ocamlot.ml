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

module Uri = struct
  include Uri
  let t_of_sexp sexp =
    of_string (Sexplib.Std.string_of_sexp sexp)
  let sexp_of_t uri = Sexplib.Std.sexp_of_string (to_string uri)
end

module Body    = Cohttp_lwt_body
module Request = Cohttp_lwt_unix.Request
module Server  = Cohttp_lwt_unix.Server
module Cookie  = Cohttp.Cookie
module Header  = Cohttp.Header

type engagement = Time.t
type history = engagement list

type worker_id = int with sexp

type worker_message =
  | Refuse of string
  | Accept
  | Check_in
  | Fail_task of string
  | Complete of Result.t
with sexp

type worker_env = Host.t * Opam_task.compiler list with sexp

type task_event =
  | Advertized of Host.t
  | Refused of worker_id * string
  | Started of worker_id
  | Checked_in of worker_id
  | Failed of worker_id * string
  | Timed_out of worker_id * Time.duration
  | Cancelled of string
  | Completed of worker_id * Result.t
with sexp

type task_log = (Time.t * task_event) list with sexp
type job = Opam of Opam_task.t with sexp
type task = {
  href : Uri.t;
  log : task_log;
  host : Host.t;
  job : job;
} with sexp
type task_offer = Uri.t * job with sexp

type task_action =
  | Worker of worker_id * worker_message
  | Time_out of worker_id * Time.duration
  | Cancel of string
type task_resource = (task * requeue, task_action) Resource.t
and requeue = Requeue of (task_resource -> unit)
and worker = {
  engagement : engagement;
  cookie : string;
  worker_id : worker_id;
  worker_env : worker_env;
  last_request : Time.t;
  assignment : task_resource option;
  finished : task_resource list;
}
type worker_action =
  | Assign of task_resource
  | Finish of task_resource
  | Quit of task_resource
type worker_resource = (worker, worker_action) Resource.t

type goal = {
  slug : string;
  title : string;
  descr : Cow.Html.t;
  subgoals : (goal, goal_action) Resource.index;
  completed : task Resource.archive;
  tasks : (task * requeue, task_action) Resource.index;
  queue : task_resource Lwt_stream.t;
  enqueue : task_resource -> unit;
  stream : task_resource Lwt_stream.t;
}
and goal_action =
  | New_task of task_resource
  | Update_task of Uri.t * task_action
  | New_subgoal of goal_resource
  | Update_subgoal of Uri.t * goal_action
and goal_resource = (goal, goal_action) Resource.t

type t_action =
  | New_worker of worker_resource
  | Update_worker of Uri.t * worker_action
  | New_goal of goal_resource
  | Update_goal of Uri.t * goal_action
type t = {
  resources : (Uri.t, (Resource.media_type -> string)) Hashtbl.t;
  goals : (goal, goal_action) Resource.index;
  outstanding : task_resource Lwt_stream.t;
  task_table : (Uri.t, task_resource) Hashtbl.t;
  workers : (worker, worker_action) Resource.index;
  idle : task_resource Lwt.u Lwt_sequence.t;
}
type t_resource = (t, t_action) Resource.t

let engagement = Time.now ()
let sessions = Hashtbl.create 10 (* cookie -> worker URI *)
let worker_id_cookie = "worker_id"
let worker_timeout = 30.

let git_state_lock = Lwt_mutex.create ()

let mint_id mint () = let id = !mint in incr mint; id
let worker_mint = ref 0
let new_worker_id = mint_id worker_mint

let string_of_job = function
  | Opam opam_task -> "opam => "^(Opam_task.to_string opam_task)

(* TODO: DO *)
let html_escape s = s

let string_of_worker_env (host,compilers) =
  (Host.to_string host)
  ^" with OCaml "
  ^(String.concat ", " (List.map Opam_task.string_of_compiler compilers))

let string_of_event = Printf.(function
  | Advertized host -> sprintf "advertized for %s host" (Host.to_string host)
  | Refused (worker_id, reason) -> sprintf
      "refused by worker %d because '%s'" worker_id (html_escape reason)
  | Started worker_id -> sprintf "started by worker %d" worker_id
  | Checked_in worker_id -> sprintf "checked-in by worker %d" worker_id
  | Failed (worker_id, reason) -> sprintf
      "failed by worker %d because '%s'" worker_id (html_escape reason)
  | Timed_out (worker_id, duration) -> sprintf
      "timed-out worker %d after %s" worker_id (Time.duration_to_string duration)
  | Cancelled reason -> sprintf
      "cancelled because '%s'" reason
  | Completed (worker_id, result) -> sprintf
      "completed by worker %d with result: %s" worker_id
    Result.(string_of_status (get_status result))
)

(* TODO: 1st class pattern match *)
let match_task { job = Opam opam_task } (worker_host, compilers) =
  let { Opam_task.target = { Opam_task.host; compiler } } = opam_task in
  host = worker_host
  && List.exists Opam_task.(fun c -> c.c_version = compiler.c_version) compilers

(* TODO: better search, yes it's linear right now *)
let find_task t worker_env =
  Printf.eprintf "looking for task: %d outstanding\n%!"
    (List.length Lwt_stream.(get_available (clone t.outstanding)));
  let rec pull rql = match Lwt_stream.get_available_up_to 1 t.outstanding with
    | [] ->
        Printf.eprintf "0 OUTSTANDING TASKS!\n%!";
        (List.rev rql), None
    | tr::_ ->
        let (task, Requeue rq) = Resource.content tr in
        if match_task task worker_env
        then (List.rev rql), Some tr
        else (Printf.eprintf "skipping task\n%!"; pull ((tr, rq)::rql))
  in
  let rql, task_opt = pull [] in
  List.iter (fun (tr, rq) -> rq tr) rql;
  task_opt

let update_worker worker action = match action with
  | Assign tr ->
      (* TODO: already assigned? *)
      { worker with assignment=Some tr; }
  | Finish tr ->
      (* TODO: not assigned? *)
      { worker with assignment=None; finished=tr::worker.finished; }
  | Quit tr ->
      begin match worker.assignment with
        | Some t -> { worker with assignment=None; } (* TODO: t != tr -> error *)
        | None -> worker (* TODO: error! *)
      end
let worker_renderer =
  let render_html event =
    let page worker =
      let assignment = match worker.assignment with
        | None -> <:html<idle>>
        | Some tr ->
            let (task,_) = Resource.content tr in
            let descr = string_of_job task.job in
            <:html<<a href="$uri:Resource.uri tr$">$str:descr$</a>&>> in
      Html.(
        to_string
          (page
             ~title:(Printf.sprintf "Knight %d" worker.worker_id)
             <:html<
               <p>Last transmission: $str:Time.to_string worker.last_request$</p>
               <p>$str:string_of_worker_env worker.worker_env$</p>
               <p>Present task assignment: $assignment$</p>
               <p>Completed <strong>$int:List.length worker.finished$</strong> tasks</p>
           >>)) in
    Resource.(match event with
      | Create (worker, r) -> page worker
      | Update (worker_action, r) -> page (content r)
    ) in
  let r = Hashtbl.create 1 in
  Hashtbl.replace r (`text `html) render_html;
  r

let lift_worker_to_t = Resource.(function
  | Create (_, r) -> New_worker r
  | Update (d, r) -> Update_worker (uri r, d)
)

let new_worker t_resource worker_env =
  let t = Resource.content t_resource in
  let cookie = Util.(hex_str_of_string (randomish_string 20)) in
  let worker_id = new_worker_id () in
  let worker = {
    engagement; cookie; worker_id; worker_env;
    assignment = None; finished = [];
    last_request = Time.now ();
  } in
  let worker_resource = Resource.index t.workers
    worker update_worker worker_renderer
  in
  let () = Hashtbl.replace sessions cookie (Resource.uri worker_resource) in
  Resource.bubble worker_resource t_resource lift_worker_to_t;
  worker_resource

let update_task (task,rq) action =
  let now = Time.now () in
  match action with
    | Worker (wid, Refuse reason) ->
        ({ task with log=(now, Refused (wid, reason))::task.log },rq)
    | Worker (wid, Accept) ->
        ({ task with log=(now, Started wid)::task.log },rq)
    | Worker (wid, Check_in) ->
        ({ task with log=(now, Checked_in wid)::task.log },rq)
    | Worker (wid, Fail_task reason) ->
        ({ task with log=(now, Failed (wid, reason))::task.log },rq)
    | Worker (wid, Complete result) ->
        ({ task with log=(now, Completed (wid, result))::task.log },rq)
    | Time_out (wid, duration) ->
        ({ task with log=(now, Timed_out (wid, duration))::task.log },rq)
    | Cancel reason ->
        ({ task with log=(now, Cancelled reason)::task.log },rq)
let task_renderer goal_resource =
  let render_html event =
    let log_event (time, event) =
      <:html< $str:string_of_event event$ at $str:Time.to_string time$ >>
    in
    let page { href; log; job } =
      let job_descr = string_of_job job in
      let (time, event) = List.hd log in
      let up_link = (Resource.content goal_resource).title in
      let result = match event with
        | Completed (wid, result) -> Some <:html<
            <div id='result'>$Result.to_html result$</div>
        >>
        | _ -> None
      in Html.(
        to_string
          (page ~title:job_descr
           <:html<
             <div id='update'>$str:Time.to_string time$</div>
             <div id='status'>$str:string_of_event event$</div>
             <div id='source'><a href="$uri:href$">$uri:href$</a></div>
             $opt:result$
             $ul (List.map log_event log)$
             <p><a href="$uri:Resource.uri goal_resource$">$str:up_link$</a></p>
           >>))
    in Resource.(match event with
      | Create ((task, _), r) -> page task
      | Update (_, r) -> page (fst (content r))
    ) in
  let r = Hashtbl.create 1 in
  Hashtbl.replace r (`text `html) render_html;
  r

let host_of_job = function
  | Opam opam_task -> Opam_task.(opam_task.target.host)

let lift_task_to_goal = Resource.(function
  | Create (_, r) -> New_task r
  | Update (d, r) -> Update_task (uri r, d)
)

let queue_job goal_resource job href =
  let goal = Resource.content goal_resource in
  let host = host_of_job job in
  let task = {
    href;
    log = [Time.now (), Advertized host];
    host;
    job;
  } in
  let task_resource = Resource.index goal.tasks
    (task, Requeue goal.enqueue) update_task (task_renderer goal_resource)
  in
  Resource.bubble task_resource goal_resource lift_task_to_goal;
  task_resource

let register_resource t r =
  Hashtbl.replace t.resources (Resource.uri r) (Resource.represent r)

let rec update_t_goal t = function
  | New_task tr ->
      register_resource t tr;
      Hashtbl.replace t.task_table (Resource.uri tr) tr;
      t
  | New_subgoal gr ->
      let open Resource in
      Hashtbl.replace t.resources (uri gr) (represent gr);
      { t with
        outstanding = Lwt_stream.choose
          (List.map
             (fun g -> (Resource.content g).stream)
             (Resource.index_to_list t.goals));
      }
  | Update_task (_,_) -> t
  | Update_subgoal (_,subgoal_event) -> update_t_goal t subgoal_event

let update_t t = function
  | New_worker wr ->
      Resource.(Hashtbl.replace t.resources (uri wr) (represent wr));
      t
  | Update_worker (_,_) -> t (* TODO: idle/assigned counter *)
  | New_goal gr -> update_t_goal t (New_subgoal gr)
  | Update_goal (_, goal_event) -> update_t_goal t goal_event

let t_renderer =
  let render_html event =
    let goal gr =
      let goal = Resource.content gr in
      <:html< <a href="$uri:Resource.uri gr$">$str:goal.title$</a> >>
    in
    let worker wr =
      let worker = Resource.content wr in
      <:html<
        <a href="$uri:Resource.uri wr$">
          #$int:worker.worker_id$ $str:string_of_worker_env worker.worker_env$
        </a>
      >>
    in
    let page t =
      Html.(
        to_string
          (page <:html<
           $ul (List.rev_map goal (Resource.index_to_list t.goals))$
           $ul (List.rev_map worker (Resource.index_to_list t.workers))$
           <p>Idle workers: $int:Lwt_sequence.length t.idle$</p>
           <p>Assigned workers: $int:
           List.length (List.filter (fun wr -> match Resource.content wr with
             | { assignment = Some _ } -> true
             | _ -> false
           ) (Resource.index_to_list t.workers))
           $</p>
           >>))
    in Resource.(match event with
      | Create (t, r) -> page t
      | Update (_, r) -> page (content r)
    ) in
  let r = Hashtbl.create 1 in
  Hashtbl.replace r (`text `html) render_html;
  r

let make ~base =
  let queue, _ = Lwt_stream.create () in
  let generate_worker_uri worker =
    Uri.(resolve "" base
           (of_string (Printf.sprintf "worker/%d" worker.worker_id)))
  in
  let generate_goal_uri goal =
    Uri.(resolve "" base (of_string goal.slug))
  in
  let goals = Resource.create_index generate_goal_uri in
  let resources = Hashtbl.create 5 in
  let t = {
    resources;
    goals;
    outstanding = queue;
    task_table = Hashtbl.create 10;
    workers = Resource.create_index generate_worker_uri;
    idle = Lwt_sequence.create ();
  } in
  let t_resource = Resource.create base t update_t t_renderer in
  let () = Resource.(
    Hashtbl.replace resources (uri t_resource) (represent t_resource)
  ) in
  t_resource

let browser_listener service_fn ~base t_resource =
  let root = Uri.path base in
  let routes = Re.(str root) in
  let t = Resource.content t_resource in
  let html = `text `html in
  let respond s = Lwt.(
    let headers = Header.add (Header.init ())
      "content-type" "application/xhtml+xml" in
    Server.respond_string ~headers ~status:`OK ~body:s ()
    >>= Http_server.some_response
  ) in
  let handler conn_id ?body req = Lwt.(
    let req_uri = Uri.resolve "http" base (Request.uri req) in
    (*Printf.eprintf "BROWSER: %s\n%!" (Uri.to_string req_uri);
    Hashtbl.iter (fun uri _ -> Printf.eprintf "       : %s\n%!" (Uri.to_string uri)) t.resources;*)
    try
      let represent = Hashtbl.find t.resources req_uri in
      respond (represent html)
    with Not_found ->
      return None
  ) in
  service_fn
    ~routes
    ~handler
    ~startup:[]

let rec monitor_job start_time worker_resource task_resource stream =
  let open Lwt in
  async (fun () -> (pick [
    Lwt_unix.sleep worker_timeout
    >>= begin fun () ->
      let worker_resource = Resource.update worker_resource
        (Quit task_resource) in
      let worker = Resource.content worker_resource in
      let _tr = Resource.update task_resource
        (Time_out (worker.worker_id,
                   Time.elapsed start_time (Time.now ()))) in
      return ()
    end;
    Lwt_stream.next stream >>= function
      | Resource.Create (_,_)
      | Resource.Update (Worker (_, Fail_task _), _)
      | Resource.Update (Worker (_, Refuse _), _)
      | Resource.Update (Worker (_, Complete _), _)
      | Resource.Update (Cancel _, _)
      | Resource.Update (Time_out (_,_), _) -> return ()
      | Resource.Update (Worker (_, Accept), tr)
      | Resource.Update (Worker (_, Check_in), tr) -> return
          (monitor_job (Time.now ()) worker_resource tr stream)
  ]))

let worker_listener service_fn ~base t_resource =
  let root = Uri.path base in
  let routes = Re.(str root) in
  let offer_task ~headers worker_resource task_resource =
    let () = Printf.eprintf "OFFERING A TASK\n%!" in
    let offer_time = Time.now () in
    let worker_resource = Resource.update worker_resource
      (Assign task_resource) in
    let (task,_) = Resource.content task_resource in
    let uri = Resource.uri task_resource in
    let sexp = sexp_of_task_offer (uri,task.job) in
    let body = Sexplib.Sexp.to_string sexp in
    let () = Printf.eprintf "SENDING %s\n%!" body in
    let stream = Resource.stream task_resource in
    let _ = Lwt_stream.get_available stream in
    monitor_job offer_time worker_resource task_resource stream;
    let open Lwt in
    Server.respond_string ~headers ~status:`OK ~body ()
    >>= Http_server.some_response
  in
  let handler conn_id ?body req = Lwt.(
    let t = Resource.content t_resource in
    let uri = Uri.resolve "" base (Request.uri req) in
    if Request.meth req <> `POST
    then return None
    else
      if Uri.path uri = root && Uri.query uri = ["queue",[]]
      then
        let req_headers = Request.headers req in
        let cookies = Cookie.Cookie_hdr.extract req_headers in
        let headers = Header.init () in
        (try
           let ident = List.assoc worker_id_cookie cookies in
           let uri = Hashtbl.find sessions ident in
            (* TODO: if post body contains different profile? *)
           return (headers, Resource.find t.workers uri)
         with Not_found -> begin
           Body.string_of_body body
           >>= fun body ->
           let () = Printf.eprintf "RECEIVED %s\n%!" body in
           let sexp = Sexplib.Sexp.of_string body in
           let worker_env = worker_env_of_sexp sexp in
           let wr = new_worker t_resource worker_env in
           let worker = Resource.content wr in
           let open Cookie.Set_cookie_hdr in
           let cookie = make (worker_id_cookie,
                              worker.cookie) in
           let k, v = Cookie.Set_cookie_hdr.serialize cookie in
           let headers = Header.add headers k v in
           return (headers, wr)
         end
        ) >>= fun (headers, wr) ->
        let worker_env = (Resource.content wr).worker_env in
        match find_task t worker_env with
          | None ->
              add_task_r t.idle
              >>= offer_task ~headers wr
          | Some task_resource -> offer_task ~headers wr task_resource
      else if Uri.query uri = [] then
        try
          Printf.eprintf "Looking for %s in task table...\n%!" (Uri.to_string uri);
          let tr = Hashtbl.find t.task_table uri in
          try
            let req_headers = Request.headers req in
            let cookies = Cookie.Cookie_hdr.extract req_headers in
            let ident = List.assoc worker_id_cookie cookies in
            let worker_uri = Hashtbl.find sessions ident in
            let wr = Resource.find t.workers worker_uri in
            let worker = Resource.content wr in
            let assignment = match worker.assignment with
              | Some assignment -> assignment | None -> raise Not_found in
            if (Resource.uri assignment) = uri
            then begin
              Body.string_of_body body
              >>= fun body ->
              let sexp = Sexplib.Sexp.of_string body in
              let message = worker_message_of_sexp sexp in
              let tr = Resource.update tr (Worker (worker.worker_id,message)) in
              begin match message with
                | Refuse _ | Fail_task _ ->
                    let _wr = Resource.update wr (Quit tr) in
                    ()
                | Complete _ ->
                    let _wr = Resource.update wr (Finish tr) in
                    ()
                | _ -> ()
              end;
              Server.respond ~status:`No_content
                ~body:None ()
              >>= Http_server.some_response
            end
            else raise Not_found
          with Not_found ->
            (* TODO: more accurate error fall-through *)
            (Server.respond_error ~status:`Forbidden
               ~body:"403: Forbidden" ()
             >>= Http_server.some_response)
        with Not_found ->
          Printf.eprintf "URI not in task table!\n%!";
          return None
      else return None
  ) in
  service_fn
    ~routes
    ~handler
    ~startup:[]
