type t = Files of string list | Dir of string

let resolve ~cli ~config ~default_dir =
  match cli with
  | Some source -> source
  | None -> Option.value config ~default:(Dir default_dir)

let files = function
  | Files files -> Ok files
  | Dir dir ->
      if Sys.file_exists dir && Sys.is_directory dir then
        Ok (Spectec.collect_spec_files dir)
      else
        Error
          (Spectec.Error.DirectoryError
             (Printf.sprintf
                "spec directory %s does not exist; pass --spec or --spec-dir"
                dir))
