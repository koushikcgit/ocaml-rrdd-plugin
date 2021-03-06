(*
 * Copyright (C) 2013 Citrix Systems Inc.
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

open Pervasiveext
open Unixext
open Threadext
open Xstringext

let (|>) x f = f x

(* This exception is setup to be raised on sigint by Process.initialise, and is
   used to cancel the synchronous function Reporter.start. *)
exception Killed

module Utils = struct
	let now () = Int64.of_float (Unix.gettimeofday ())

	let cut str =
		String.split_f (fun c -> c = ' ' || c = '\t') str

	let list_directory_unsafe name =
		let handle = Unix.opendir name in
		let rec read_directory_contents acc handle =
			try
				let next_entry = Unix.readdir handle in
				read_directory_contents (next_entry :: acc) handle
			with End_of_file -> List.rev acc
		in
		finally
			(fun () -> read_directory_contents [] handle)
			(fun () -> Unix.closedir handle)

	let list_directory_entries_unsafe dir =
		let dirlist = list_directory_unsafe dir in
		List.filter (fun x -> x <> "." && x <> "..") dirlist

	let exec_cmd (module D : Debug.DEBUG) ~cmdstring ~(f : string -> 'a option) =
		D.debug "Forking command %s" cmdstring;
		(* create pipe for reading from the command's output *)
		let (out_readme, out_writeme) = Unix.pipe () in
		let cmd, args = match String.split ' ' cmdstring with [] -> assert false | h::t -> h,t in
		let pid = Forkhelpers.safe_close_and_exec None (Some out_writeme) None [] cmd args in
		Unix.close out_writeme;
		let in_channel = Unix.in_channel_of_descr out_readme in
		let vals = ref [] in
		let rec loop () =
			let line = input_line in_channel in
			let ret = f line in
			begin
				match ret with
				| None -> ()
				| Some v -> vals := v :: !vals
			end;
			loop ()
		in
		(try loop () with End_of_file -> ());
		Unix.close out_readme;
		let (pid, status) = Forkhelpers.waitpid pid in
		begin
			match status with
			| Unix.WEXITED n   -> D.debug "Process %d exited normally with code %d" pid n
			| Unix.WSIGNALED s -> D.debug "Process %d was killed by signal %d" pid s
			| Unix.WSTOPPED s  -> D.debug "Process %d was stopped by signal %d" pid s
		end;
		List.rev !vals
end

(* Establish a XMLPRC interface with RRDD *)
module RRDD = Rrd_client.Client

module Xs = struct
	module Xs = Xs_client_unix.Client(Xs_transport_unix_client)
	include Xs

	type xs_state = {
		my_domid: int32;
		root_path: string;
		client: Xs.client;
	}

	let cached_xs_state = ref None

	let cached_xs_state_m = Mutex.create ()

	let get_xs_state () =
		Mutex.execute cached_xs_state_m
			(fun () ->
				match !cached_xs_state with
				| Some state -> state
				| None ->
					(* This creates a background thread, so must be done after daemonising. *)
					let client = Xs.make () in
					let my_domid =
						Xs.immediate
							client
							(fun handle -> Xs.read handle "domid")
						|> Int32.of_string
					in
					let root_path = Printf.sprintf "/local/domain/%ld/rrd" my_domid in
					let state = {
						my_domid;
						root_path;
						client
					}
					in cached_xs_state := Some state;
					state)
end

module Reporter = struct
	type state =
		| Running
		| Cancelled
		| Stopped

	type target =
		| Local
		| Interdomain of (int * int)

	type t = {
		mutable state: state;
		lock: Mutex.t;
		condition: Condition.t;
	}

	let make () = {
		state = Running;
		lock = Mutex.create ();
		condition = Condition.create ();
	}

	let choose_protocol = function
		| Rrd_interface.V1 -> Rrd_protocol_v1.protocol
		| Rrd_interface.V2 -> Rrd_protocol_v2.protocol

	let wait_until_next_reading
			(module D : Debug.DEBUG)
			?(neg_shift=0.5)
			~uid
			~protocol =
		let next_reading =
			RRDD.Plugin.Local.register uid Rrd.Five_Seconds protocol
		in
		let wait_time = next_reading -. neg_shift in
		let wait_time = if wait_time < 0.1 then wait_time+.5. else wait_time in
		if wait_time > 0. then Thread.delay wait_time
		else
			D.debug "rrdd says next reading is overdue by %.1f seconds; not sleeping" (-.wait_time)

	let loop (module D : Debug.DEBUG) ~reporter ~report ~cleanup =
		let running = ref true in
		while !running do
			try
				report ();
				match reporter with
				| Some reporter -> begin
					(* Handle asynchronous cancellation. *)
					Mutex.execute reporter.lock
						(fun () ->
							match reporter.state with
							| Running -> ()
							| Stopped
							| Cancelled ->
								reporter.state <- Stopped;
								cleanup ();
								Condition.broadcast reporter.condition;
								running := false)
				end
				| None -> ()
			with
				| Sys.Break | Killed ->
					(* Handle cancellation via signal handler. *)
					cleanup ();
					running := false
				| e ->
					D.error
						"Unexpected error %s, sleeping for 10 seconds..."
						(Printexc.to_string e);
					D.log_backtrace ();
					Thread.delay 10.0
		done

	let start_local (module D : Debug.DEBUG) ~reporter ~uid ~neg_shift ~protocol ~dss_f =
		let path = RRDD.Plugin.get_path ~uid in
		D.info "Obtained path=%s\n" path;
		let _ = mkdir_safe (Filename.dirname path) 0o644 in
		let _, writer =
			Rrd_writer.FileWriter.create path (choose_protocol protocol)
		in
		let report () =
			wait_until_next_reading
				(module D)
				~neg_shift
				~uid
				~protocol;
			let payload = Rrd_protocol.({
				timestamp = Utils.now ();
				datasources = dss_f ();
			}) in
			writer.Rrd_writer.write_payload payload;
			Thread.delay 0.003
		in
		let cleanup () =
			RRDD.Plugin.Local.deregister ~uid;
			writer.Rrd_writer.cleanup ()
		in
		loop (module D : Debug.DEBUG) ~reporter ~report ~cleanup

	let start_interdomain
			(module D : Debug.DEBUG)
			~reporter
			~uid
			~backend_domid
			~page_count
			~protocol
			~dss_f =
		let id = Rrd_writer.({
			backend_domid = backend_domid;
			shared_page_count = page_count;
		}) in
		let shared_page_refs, writer =
			Rrd_writer.PageWriter.create id (choose_protocol protocol)
		in
		let xs_state = Xs.get_xs_state () in
		Xs.transaction xs_state.Xs.client (fun xs ->
			Xs.write xs
				(Printf.sprintf "%s/%s/grantrefs" xs_state.Xs.root_path uid)
				(List.map string_of_int shared_page_refs |> String.concat ",");
			Xs.write xs
				(Printf.sprintf "%s/%s/protocol" xs_state.Xs.root_path uid)
				(Rpc.string_of_rpc (Rrd_interface.rpc_of_plugin_protocol protocol));
			Xs.write xs
				(Printf.sprintf "%s/%s/ready" xs_state.Xs.root_path uid)
				"true");
		let report () =
			let payload = Rrd_protocol.({
				timestamp = Utils.now ();
				datasources = dss_f ();
			}) in
			writer.Rrd_writer.write_payload payload;
			Thread.delay 5.0
		in
		let cleanup () =
			Xs.immediate xs_state.Xs.client (fun xs ->
				Xs.write xs
					(Printf.sprintf "%s/%s/shutdown" xs_state.Xs.root_path uid)
					"true");
			writer.Rrd_writer.cleanup ()
		in
		loop (module D) ~reporter ~report ~cleanup

	let start (module D : Debug.DEBUG) ~uid ~neg_shift ~target ~protocol ~dss_f =
		match target with
		| Local ->
			start_local (module D)
				~reporter:None
				~uid
				~neg_shift
				~protocol
				~dss_f
		| Interdomain (backend_domid, page_count) ->
			start_interdomain (module D)
				~reporter:None
				~uid
				~backend_domid
				~page_count
				~protocol
				~dss_f

	let start_async (module D : Debug.DEBUG) ~uid ~neg_shift ~target ~protocol ~dss_f =
		let reporter = make () in
		let (_ : Thread.t) =
			Thread.create (fun () ->
				match target with
				| Local ->
					start_local (module D)
						~reporter:(Some reporter)
						~uid
						~neg_shift
						~protocol
						~dss_f
				| Interdomain (backend_domid, page_count) ->
					start_interdomain (module D)
						~reporter:(Some reporter)
						~uid
						~backend_domid
						~page_count
						~protocol
						~dss_f)
			()
		in
		reporter

	let get_state ~reporter =
		Mutex.execute reporter.lock (fun () -> reporter.state)

	let cancel ~reporter =
		Mutex.execute reporter.lock
			(fun () ->
				match reporter.state with
				| Running -> begin
					reporter.state <- Cancelled;
					Condition.wait reporter.condition reporter.lock
				end
				| Cancelled -> Condition.wait reporter.condition reporter.lock
				| Stopped -> ())

	let wait_until_stopped ~reporter =
		Mutex.execute reporter.lock
			(fun () -> Condition.wait reporter.condition reporter.lock)
end

module Process = functor (N : (sig val name : string end)) -> struct
	module D = Debug.Make(struct let name=N.name end)

	let on_sigterm signum =
		D.info "Received signal %d: deregistering plugin %s..." signum N.name;
		raise Killed

	let initialise () =
		Sys.set_signal Sys.sigterm (Sys.Signal_handle on_sigterm);

		(* CA-92551, CA-97938: Use syslog's local0 facility *)
		Debug.set_facility Syslog.Local0;

		let pidfile = ref "" in
		let daemonize = ref false in
		Arg.parse (Arg.align [
			"-daemon", Arg.Set daemonize, "Create a daemon";
			"-pidfile", Arg.Set_string pidfile,
			Printf.sprintf "Set the pid file (default \"%s\")" !pidfile;
		])
			(fun _ -> failwith "Invalid argument")
			(Printf.sprintf "Usage: %s [-daemon] [-pidfile filename]" N.name);
			
		if !daemonize then (
			D.debug "Daemonizing ..";
			Unixext.daemonize ()
		) else (
			D.debug "Not daemonizing ..";
			Sys.catch_break true;
			Debug.log_to_stdout ()
		);

		if !pidfile <> "" then
			(D.debug "Storing process id into specified file ..";
			 Unixext.mkdir_rec (Filename.dirname !pidfile) 0o755;
			 Unixext.pidfile_write !pidfile)

	let main_loop ~neg_shift ~target ~protocol ~dss_f =
		Reporter.start
			(module D)
			~uid:N.name
			~neg_shift
			~target
			~protocol
			~dss_f
end
