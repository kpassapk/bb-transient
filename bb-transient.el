;;; bb-transient.el --- Transient menus for a project's babashka tasks -*- lexical-binding: t; -*-

;; Author: Kyle Passarelli
;; URL: https://github.com/kpassapk/bb-transient
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1") (transient "0.4"))
;; Keywords: tools, processes, babashka, clojure

;; This file is not part of GNU Emacs.

;;; Commentary:

;; `bb-transient' turns the task CLI in a project's bb.edn into nested
;; transient menus and runs the chosen command from the project root.
;;
;; The command tree is not scraped from --help.  bb itself reads it:
;; bb-transient.clj walks :tasks and their :cmd tables, resolves each
;; :exec-fn, and reports the babashka.cli :spec on the fn's
;; `:org.babashka/cli' metadata.  So
;;
;;   work {:cmd {"new" {:exec-fn work/new-book}}}
;;
;;   (defn new-book
;;     {:org.babashka/cli {:spec {:title {:desc "Workbook title" :require true}}}}
;;     ...)
;;
;; becomes the menu bb > work > new, with a --title= option marked
;; required.  A :coerce :boolean option becomes a switch.  A leaf with no
;; options runs as soon as its key is pressed.
;;
;; Results are cached per project and refreshed when bb.edn changes;
;; `g' in the top menu forces a refresh after editing a spec.
;;
;; Commands run in a `compilation-mode' buffer.  TUIs need a real
;; terminal, so a command marked `:bb-transient/terminal true' (in its
;; task map or on its :exec-fn's metadata) runs in an interactive
;; `ghostel-compile' buffer instead.  `t' in an options menu, or a
;; prefix argument on a bare leaf, flips the choice for one run.
;;
;; An option can be filled in from where point is.  bb.edn's
;; `:bb-transient/defaults' maps option names to cljbang forms:
;;
;;   :bb-transient/defaults {:id (el/org-entry-get nil "ID" true)}
;;
;; fills --id= in every options menu that has it, evaluated in the
;; buffer the menu was opened from.  This needs the cljbang package.
;;
;; A command can have cljbang hooks too: `:bb-transient/before' runs
;; just before it starts and may rewrite its arguments, and
;; `:bb-transient/after' runs when it exits, with its exit code and
;; output.  A hook is an (fn ...) form or a qualified symbol, whose
;; namespace is required from bb.edn's `:bb-transient/cljbang-paths'.
;;
;; A menu can show other projects' tasks too, a group per project:
;; each function in `bb-transient-layers-functions' names some.  Their
;; commands run from the current project with their own bb.edn as
;; --config, and the current project's tasks hide theirs by name.

;;; Code:

(require 'compile)
(require 'transient)

(declare-function ghostel-compile "ghostel-compile" (command &optional interactive))
(declare-function cljbang-eval-string "cljbang" (s))
(declare-function cljbang-require "cljbang" (ns &optional reload))
(declare-function cljbang-ex-message "cljbang-core" (e))
(defvar cljbang-load-path)
(defvar ghostel-compile-buffer-name)

(defgroup bb-transient nil
  "Transient menus for babashka tasks."
  :group 'tools
  :prefix "bb-transient-")

(defcustom bb-transient-program "bb"
  "The babashka executable."
  :type 'string)

(defcustom bb-transient-use-comint t
  "Non-nil runs commands in `comint' mode, so they can read input.
The buffer is still a `compilation-mode' buffer either way."
  :type 'boolean)

(defcustom bb-transient-project-function #'bb-transient-project-root
  "Function returning the directory of the project whose menu to show.
It is called with no arguments in the buffer the menu is opened from.
Set it to pick a project some other way than the nearest bb.edn, such
as from an Org property."
  :type 'function)

(defcustom bb-transient-directory-function #'bb-transient-project
  "Function returning the directory commands run from.
It is called with no arguments in the buffer the menu was opened
from.  When the result isn't the project a command comes from, that
project's bb.edn is passed as --config.  To run from the buffer's own
directory instead of its project's root, use
\=(lambda () default-directory)."
  :type 'function)

(defcustom bb-transient-eval-hooks 'ask
  "Whether to evaluate a project's forms in Emacs.
The forms are the `:bb-transient/defaults' and the before and after
hooks in its bb.edn.  t
evaluates them, nil never does, and `ask' asks once per project and
session."
  :type '(choice (const :tag "Always" t)
                 (const :tag "Never" nil)
                 (const :tag "Ask once per project" ask)))

(defvar bb-transient-layers-functions nil
  "Functions naming other projects to show in the menu.
Each is called with the current project's directory and returns a
list of (LABEL . DIRECTORY), outermost first.  Each DIRECTORY's bb.edn
tasks become a group headed LABEL, above the current project's own,
and an inner project's task hides an outer one of the same name.
A function that returns the current project itself labels its group.
Commands still run from the current project; see
`bb-transient-directory-function'.")

(defconst bb-transient--script
  (expand-file-name "bb-transient.clj"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The introspection script that ships with this package.")

;;;; Reading the command tree

(defvar bb-transient--cache (make-hash-table :test #'equal)
  "Project root -> (MTIME . RESULT), RESULT the parsed introspection.")

(defun bb-transient-project-root (&optional directory)
  "The directory holding the nearest bb.edn at or above DIRECTORY, or signal.
DIRECTORY defaults to `default-directory'."
  (let ((dir (or directory default-directory)))
    (expand-file-name
     (or (locate-dominating-file dir "bb.edn")
         (user-error "No bb.edn in %s or above" dir)))))

(define-obsolete-function-alias 'bb-transient--root
  #'bb-transient-project-root "0.2.0")

(defun bb-transient-project ()
  "The current project's directory, from `bb-transient-project-function'."
  (file-name-as-directory (expand-file-name (funcall bb-transient-project-function))))

(defun bb-transient--introspect (root)
  "Run the introspection script in ROOT and return its parsed output.
An alist of `tasks' and, if bb.edn has them, `cljbang-paths'."
  (let ((default-directory root)
        (config (expand-file-name "bb.edn" root))
        (stderr (make-temp-file "bb-transient-err")))
    (unwind-protect
        (with-temp-buffer
          (let ((status (call-process bb-transient-program nil (list t stderr) nil
                                      "--config" config "-f" bb-transient--script config)))
            (unless (eql status 0)
              (error "bb-transient: introspecting %s failed (exit %s): %s"
                     config status
                     (with-temp-buffer
                       (insert-file-contents stderr)
                       (string-trim (buffer-string)))))
            ;; Namespaces may print as they load; the JSON is the last line.
            (goto-char (point-max))
            (forward-line -1)
            (json-parse-buffer :object-type 'alist :array-type 'list
                               :null-object nil :false-object nil)))
      (delete-file stderr))))

(defun bb-transient--read (root &optional refresh)
  "The introspection of the project in ROOT, cached until bb.edn changes.
REFRESH reads it again regardless."
  (let* ((root (file-name-as-directory (expand-file-name root)))
         (mtime (file-attribute-modification-time
                 (file-attributes (expand-file-name "bb.edn" root))))
         (hit (gethash root bb-transient--cache)))
    (if (and hit (not refresh) (equal (car hit) mtime))
        (cdr hit)
      (let ((result (bb-transient--introspect root)))
        (puthash root (cons mtime result) bb-transient--cache)
        result))))

(defun bb-transient-tasks (root &optional refresh)
  "The bb tasks of the project in ROOT, as a list of nodes.
Cached until bb.edn changes, or REFRESH.  A node is an alist:

  name      the task or subcommand name
  doc       its one-line doc, or nil
  children  for a :cmd table, its nodes
  options   for a leaf, its babashka.cli options, each an alist of
            name, desc, alias, require, default and boolean
  terminal  non-nil when it should run in a terminal
  defaults  for a leaf, an alist of option name to cljbang source
  before    the cljbang source of its before hook, or nil
  after     the same for its after hook
  error     why its :exec-fn or :cmd could not be resolved"
  (alist-get 'tasks (bb-transient--read root refresh)))

(defun bb-transient--cljbang-paths (root)
  "ROOT's `:bb-transient/cljbang-paths', as absolute directories."
  (mapcar (lambda (dir) (expand-file-name dir root))
          (alist-get 'cljbang-paths (bb-transient--read root))))

(define-obsolete-function-alias 'bb-transient--tree
  #'bb-transient-tasks "0.2.0")

;;;; Keys

(defun bb-transient--key (name taken &optional prefix)
  "Pick a one-character key for NAME not in TAKEN, prepending PREFIX.
Prefers the letters of NAME in order, then any letter or digit."
  (let ((candidates (append (string-to-list (downcase name))
                            (string-to-list (upcase name))
                            (string-to-list "abcdefghijklmnopqrstuvwxyz0123456789"))))
    (seq-some (lambda (c)
                (let ((k (concat prefix (string c))))
                  (and (or (<= ?a c ?z) (<= ?A c ?Z) (<= ?0 c ?9))
                       (not (member k taken))
                       k)))
              candidates)))

;;;; Building menus

(defun bb-transient--sym (root path)
  "The command symbol for PATH (a list of names) in project ROOT."
  (intern (format "bb-transient:%s/%s"
                  (substring (md5 root) 0 6)
                  (string-join (or path '("bb")) "/"))))

(defun bb-transient--describe (node)
  "One-line description of NODE for the menu."
  (let ((doc (alist-get 'doc node))
        (err (alist-get 'error node)))
    (concat (alist-get 'name node)
            (when doc (concat "  " (propertize doc 'face 'transient-inactive-value)))
            (when err (concat "  " (propertize "(unresolved)" 'face 'error))))))

(defun bb-transient--option-suffix (opt taken)
  "Transient infix spec for babashka.cli option OPT, avoiding keys in TAKEN."
  (let* ((name (alist-get 'name opt))
         (alias (alist-get 'alias opt))
         (key (if (and alias (= (length alias) 1)
                       (not (member (concat "-" alias) taken)))
                  (concat "-" alias)
                (bb-transient--key name taken "-")))
         (default (alist-get 'default opt))
         (desc (concat (or (alist-get 'desc opt) name)
                       (when (alist-get 'require opt)
                         (propertize " (required)" 'face 'warning))
                       (when default (format " (default %s)" default)))))
    (if (alist-get 'boolean opt)
        (list key desc (concat "--" name))
      (list key desc (concat "--" name "=")))))

(defun bb-transient--define (root path node)
  "Define the command for NODE at PATH in ROOT and return its symbol.
A node with children or options becomes a transient prefix; a bare
leaf becomes a command that runs straight away."
  (let ((sym (bb-transient--sym root path))
        (children (alist-get 'children node))
        (options (alist-get 'options node))
        (terminal (alist-get 'terminal node)))
    (put sym 'bb-transient-root root)
    (put sym 'bb-transient-path path)
    (put sym 'bb-transient-options options)
    (put sym 'bb-transient-defaults (alist-get 'defaults node))
    (put sym 'bb-transient-hooks (bb-transient--hooks root node))
    (cond
     (children (bb-transient--define-menu sym root path node children))
     (options (bb-transient--define-leaf sym node options))
     (t (defalias sym
          (lambda (&optional flip)
            (interactive "P")
            (bb-transient--run root path nil (xor terminal flip)
                               (get sym 'bb-transient-hooks)))
          (alist-get 'doc node))))
    sym))

(defun bb-transient--define-menu (sym root path node children)
  "Define SYM as a menu over CHILDREN of NODE at PATH in ROOT."
  (let* ((taken (list "q"))
         (suffixes
          (mapcar (lambda (child)
                    (let ((key (bb-transient--key (alist-get 'name child) taken)))
                      (push key taken)
                      (list key (bb-transient--describe child)
                            (bb-transient--define
                             root (append path (list (alist-get 'name child))) child))))
                  children))
         (heading (concat "bb " (string-join path " "))))
    (eval
     `(transient-define-prefix ,sym ()
        ,(or (alist-get 'doc node) heading)
        [,heading ,@suffixes])
     t)))

(defun bb-transient--define-leaf (sym node options)
  "Define SYM as an options menu for leaf NODE with OPTIONS."
  (let* ((taken '("-=" "RET"))
         (infixes (mapcar (lambda (opt)
                            (let ((s (bb-transient--option-suffix opt taken)))
                              (push (car s) taken)
                              s))
                          options))
         (heading (concat "bb " (string-join (get sym 'bb-transient-path) " "))))
    (eval
     `(transient-define-prefix ,sym ()
        ,(or (alist-get 'doc node) heading)
        ,@(when (alist-get 'terminal node) '(:value '("++terminal")))
        :init-value #'bb-transient--init-value
        [,(concat heading
                  (when-let* ((doc (alist-get 'doc node)))
                    (concat "  " (propertize doc 'face 'transient-inactive-value))))
         ,@infixes
         ("-=" "Extra arguments" "++=" :prompt "Extra arguments: ")]
        [("RET" "Run" bb-transient-run-current)
         ("t" "In a terminal" "++terminal")])
     t)))

;;;; Filling in options

(defvar bb-transient--trust (make-hash-table :test #'equal)
  "Project root -> t or `no', answers to `bb-transient-eval-hooks' `ask'.")

(defvar bb-transient--compiled (make-hash-table :test #'equal)
  "Cljbang source -> a function of no arguments evaluating it.")

(defun bb-transient--trusted-p (root)
  "Whether ROOT's forms may be evaluated, asking if need be."
  (pcase bb-transient-eval-hooks
    ('nil nil)
    ('ask (let ((answer (or (gethash root bb-transient--trust)
                            (puthash root
                                     (if (y-or-n-p (format "Evaluate the Lisp in %sbb.edn? "
                                                           (abbreviate-file-name root)))
                                         t
                                       'no)
                                     bb-transient--trust))))
            (eq answer t)))
    (_ t)))

(defun bb-transient--cljbang-p ()
  "Non-nil when cljbang is loaded; otherwise say so, once."
  (or (require 'cljbang nil t)
      (progn
        (unless (get 'bb-transient--cljbang-p 'warned)
          (put 'bb-transient--cljbang-p 'warned t)
          (message "bb-transient: install cljbang to use the forms in bb.edn"))
        nil)))

(defun bb-transient--error-message (err)
  "ERR's message; for a cljbang throw, the thrown value's."
  (if (eq (car err) 'cljbang-error)
      (let ((x (cadr err)))
        (or (cljbang-ex-message x) (format "%s" x)))
    (error-message-string err)))

(defun bb-transient--compile (source)
  "A function of no arguments evaluating cljbang SOURCE, cached."
  (or (gethash source bb-transient--compiled)
      (puthash source (cljbang-eval-string (format "(fn [] %s)" source))
               bb-transient--compiled)))

(defun bb-transient--has-forms (tree)
  "Non-nil when a node in TREE has defaults or hooks to evaluate."
  (seq-some (lambda (node)
              (or (alist-get 'defaults node)
                  (alist-get 'before node)
                  (alist-get 'after node)
                  (bb-transient--has-forms (alist-get 'children node))))
            tree))

(defun bb-transient--fill (root options defaults)
  "Arguments for OPTIONS filled in by DEFAULTS, evaluated here.
DEFAULTS is a leaf's alist of option name to cljbang source from
ROOT's bb.edn.  An option whose form returns nil or signals is left
out; one that signals also gets a message."
  (when (and defaults (bb-transient--cljbang-p) (bb-transient--trusted-p root))
    (seq-keep
     (pcase-lambda (`(,name . ,source))
       (let* ((name (symbol-name name))
              (opt (seq-find (lambda (o) (equal (alist-get 'name o) name)) options))
              (value (condition-case err
                         (funcall (bb-transient--compile source))
                       (error (message "bb-transient: --%s: %s"
                                       name (bb-transient--error-message err))
                              nil))))
         (cond ((or (null opt) (null value)) nil)
               ((alist-get 'boolean opt) (concat "--" name))
               (t (format "--%s=%s" name value)))))
     defaults)))

(defun bb-transient--init-value (obj)
  "Set options menu OBJ's value: the usual one, with options filled in.
A filled-in option replaces the value transient set or saved, since
the menu should reflect where point is.  It is called in the buffer
the menu is opened from, as transient keeps that buffer current."
  (let* ((sym (oref obj command))
         (value (if-let* ((saved (assq sym transient-values)))
                    (cdr saved)
                  (transient-default-value obj)))
         (filled (bb-transient--fill (get sym 'bb-transient-root)
                                     (get sym 'bb-transient-options)
                                     (get sym 'bb-transient-defaults)))
         (names (mapcar (lambda (a) (car (split-string a "="))) filled)))
    (oset obj value
          (append (seq-remove (lambda (a) (member (car (split-string a "=")) names))
                              value)
                  filled))))

;;;; Hooks

(defvar bb-transient--required (make-hash-table :test #'equal)
  "Hook namespaces required since the last refresh.")

(defun bb-transient--hooks (root node)
  "NODE's hooks from ROOT's bb.edn, an alist, or nil if it has none.
The keys are `before' and `after', each cljbang source, and `paths',
the directories to add to `cljbang-load-path' while one runs."
  (when (or (alist-get 'before node) (alist-get 'after node))
    `((root . ,root)
      (before . ,(alist-get 'before node))
      (after . ,(alist-get 'after node))
      (paths . ,(bb-transient--cljbang-paths root)))))

(defun bb-transient--hook-fn (source)
  "A function of one argument for hook SOURCE, compiled once.
SOURCE is an (fn ...) form, or a qualified symbol whose namespace is
first required from `cljbang-load-path'."
  (if (string-prefix-p "(" source)
      (funcall (bb-transient--compile source))
    (when-let* ((slash (string-search "/" source)))
      (let ((ns (substring source 0 slash)))
        (unless (gethash ns bb-transient--required)
          ;; Reload, so `g' picks up an edited hook file.
          (cljbang-require ns t)
          (puthash ns t bb-transient--required))))
    (funcall (bb-transient--compile (format "(fn [m] (%s m))" source)))))

(defun bb-transient--call-hook (hooks key arg)
  "Call the KEY hook in HOOKS with ARG, a plist made into a map.
Its value, or nil when there is no such hook.  The map is a hash table
keyed by keywords, as cljbang's own maps are."
  (when-let* ((source (alist-get key hooks)))
    (let ((m (make-hash-table :test #'eq))
          (cljbang-load-path (append (alist-get 'paths hooks) cljbang-load-path)))
      (while arg
        (puthash (pop arg) (pop arg) m))
      (funcall (bb-transient--hook-fn source) m))))

(defun bb-transient--usable-hooks (hooks path)
  "HOOKS, or nil with a message when they can't run for bb PATH."
  (when hooks
    (if (and (require 'cljbang nil t)
             (bb-transient--trusted-p (alist-get 'root hooks)))
        hooks
      (message "bb-transient: running bb %s without its hooks (%s)"
               (string-join path " ")
               (if (featurep 'cljbang) "not trusted" "no cljbang"))
      nil)))

(defun bb-transient--watch (buf start args hooks origin)
  "Call the after hook in HOOKS when BUF's process exits.
The output starts at START and ends at the process mark, before
compile's footer; nil START means all of BUF's text.  ARGS are the
command's arguments.  The hook runs in ORIGIN, or in BUF once ORIGIN
is gone."
  (let ((proc (get-buffer-process buf)))
    (if (not proc)
        (message "bb-transient: no process in %s for the after hook" (buffer-name buf))
      (add-function
       :after (process-sentinel proc)
       (lambda (proc _event)
         (unless (process-live-p proc)
           (let ((out (with-current-buffer buf
                        (if start
                            (buffer-substring-no-properties
                             (min start (point-max))
                             (or (marker-position (process-mark proc)) (point-max)))
                          (buffer-substring-no-properties (point-min) (point-max))))))
             (with-current-buffer (if (buffer-live-p origin) origin buf)
               (condition-case err
                   (bb-transient--call-hook
                    hooks 'after (list :exit (process-exit-status proc)
                                       :out out :buffer buf
                                       :args (vconcat args)))
                 (error (message "bb-transient: after hook: %s"
                                 (bb-transient--error-message err))))))))))))

;;;; Running

(defun bb-transient--args (args)
  "Turn transient ARGS into a bb argument list.
The `++=' extra-arguments value is split like a shell command line,
and the `++terminal' switch is dropped."
  (mapcan (lambda (a)
            (cond ((equal a "++terminal") nil)
                  ((string-prefix-p "++=" a)
                   (split-string-shell-command (substring a 3)))
                  (t (list a))))
          args))

(defun bb-transient--missing (options args)
  "Names of the required OPTIONS that ARGS does not set."
  (seq-keep (lambda (opt)
              (let ((name (alist-get 'name opt)))
                (and (alist-get 'require opt)
                     (not (seq-some (lambda (a)
                                      (or (equal a (concat "--" name))
                                          (string-prefix-p (concat "--" name "=") a)))
                                    args))
                     name)))
            options))

(defun bb-transient--quote (arg)
  "Quote ARG for the shell, leaving it bare when that is already safe."
  (if (string-match-p "\\`[[:alnum:]_./=:,@+-]+\\'" arg)
      arg
    (shell-quote-argument arg)))

(defun bb-transient--command (path args &optional config)
  "The shell command line for bb PATH with ARGS.
With CONFIG, a bb.edn file, pass it as --config."
  (mapconcat #'bb-transient--quote
             (append (list bb-transient-program)
                     (when config (list "--config" config))
                     path args)
             " "))

(defun bb-transient--directory (root)
  "Where to run a command from project ROOT's bb.edn.
See `bb-transient-directory-function'; ROOT when it has no answer."
  (expand-file-name
   (or (ignore-errors (funcall bb-transient-directory-function)) root)))

(defun bb-transient--run (root path args &optional terminal hooks)
  "Run bb PATH with ARGS, using ROOT's bb.edn, and return the output buffer.
It runs from `bb-transient--directory', passing ROOT's bb.edn as
--config when that is not ROOT.  The buffer is a compilation buffer,
or with TERMINAL an interactive `ghostel-compile' buffer, so TUIs get
a real terminal.

HOOKS, from `bb-transient--hooks', are called here: before with the
args and directory, which may return new args, and after once the
process exits.  A before hook that signals cancels the run, and
returns nil."
  (let* ((hooks (bb-transient--usable-hooks hooks path))
         (origin (current-buffer))
         (default-directory (bb-transient--directory root))
         (args (condition-case err
                   (if-let* ((new (bb-transient--call-hook
                                   hooks 'before (list :args (vconcat args)
                                                       :dir default-directory))))
                       (append new nil)
                     args)
                 (error (message "bb-transient: before hook, not running: %s"
                                 (bb-transient--error-message err))
                        'cancel))))
    (unless (eq args 'cancel)
      (let* ((config (unless (file-equal-p default-directory root)
                       (expand-file-name "bb.edn" root)))
             (command (bb-transient--command path args config))
             (name (format "*bb %s*" (string-join path " ")))
             (buf (if terminal
                      (progn
                        (unless (require 'ghostel-compile nil t)
                          (user-error "Running in a terminal needs the ghostel package"))
                        (let ((ghostel-compile-buffer-name name))
                          (ghostel-compile command t)))
                    (let ((compilation-buffer-name-function (lambda (_mode) name)))
                      (compile command bb-transient-use-comint)))))
        (when (alist-get 'after hooks)
          ;; The process can't have written yet: its filter only runs
          ;; once Emacs waits.  A terminal's output is its whole text.
          (bb-transient--watch buf (unless terminal (with-current-buffer buf (point-max)))
                               args hooks origin))
        buf))))

(defun bb-transient-run (path &optional args project terminal)
  "Run bb task PATH (a list of names) with ARGS and return its buffer.
PROJECT is the directory whose bb.edn defines the task; nil means the
current project.  It runs from `bb-transient-directory-function', in
a compilation buffer, or with TERMINAL a `ghostel-compile' one."
  (bb-transient--run (or project (bb-transient-project)) path args terminal))

(transient-define-suffix bb-transient-run-current ()
  "Run the command the current menu describes."
  (interactive)
  (let* ((sym transient-current-command)
         (raw (transient-args sym))
         (args (bb-transient--args raw))
         (missing (bb-transient--missing (get sym 'bb-transient-options) args)))
    (when missing
      (user-error "Required: %s"
                  (mapconcat (lambda (n) (concat "--" n)) missing ", ")))
    (bb-transient--run (get sym 'bb-transient-root)
                       (get sym 'bb-transient-path)
                       args
                       (member "++terminal" raw)
                       (get sym 'bb-transient-hooks))))

;;;; Entry points

(defun bb-transient--layers (root)
  "The projects in ROOT's menu as (LABEL . DIRECTORY), outermost first.
The last is ROOT, labelled by its directory name unless a function in
`bb-transient-layers-functions' labels it."
  (let ((root (file-name-as-directory (expand-file-name root)))
        found layers)
    (run-hook-wrapped
     'bb-transient-layers-functions
     (lambda (fn)
       (condition-case err
           (setq found (append found (funcall fn root)))
         (error (message "bb-transient: %s failed: %s" fn (error-message-string err))))
       nil))
    (let ((label (file-name-nondirectory (directory-file-name root))))
      ;; Innermost first, so a project listed twice keeps its inner place.
      (dolist (layer (reverse found))
        (let ((dir (file-name-as-directory (expand-file-name (cdr layer)))))
          (cond ((file-equal-p dir root) (setq label (car layer)))
                ((seq-find (lambda (l) (file-equal-p (cdr l) dir)) layers))
                (t (push (cons (car layer) dir) layers)))))
      (append layers (list (cons label root))))))

(defun bb-transient--setup (root &optional refresh)
  "Define the top menu for ROOT and its layers, and return its symbol.
A group per layer, ROOT's first and the outermost last.  Keys go to the
innermost layer first, so ROOT's tasks get the letters of their names.
A layer whose
tasks can't be read is left out, unless it is ROOT.  REFRESH also
recompiles the defaults and hooks, and requires hook namespaces again."
  (when refresh
    (clrhash bb-transient--compiled)
    (clrhash bb-transient--required))
  (let* ((root (file-name-as-directory (expand-file-name root)))
         (layers (bb-transient--layers root))
         (sym (intern (format "bb-transient:%s"
                              (substring (md5 (prin1-to-string layers)) 0 6))))
         (taken (list "q" "g"))
         seen groups)
    (pcase-dolist (`(,label . ,dir) (reverse layers))
      (when-let* ((tree (condition-case err
                            (bb-transient-tasks dir refresh)
                          (error (if (file-equal-p dir root)
                                     (signal (car err) (cdr err))
                                   (message "bb-transient: skipping %s: %s"
                                            label (error-message-string err))
                                   nil)))))
        (let ((tree (seq-remove (lambda (n) (member (alist-get 'name n) seen)) tree)))
          ;; Ask now, not while a menu is up.
          (when (and (bb-transient--has-forms tree) (bb-transient--cljbang-p))
            (bb-transient--trusted-p dir))
          (setq seen (append seen (mapcar (lambda (n) (alist-get 'name n)) tree)))
          (push (vconcat
                 (list (if (cdr layers) label "bb tasks"))
                 (mapcar (lambda (node)
                           (let ((key (bb-transient--key (alist-get 'name node) taken)))
                             (push key taken)
                             (list key (bb-transient--describe node)
                                   (bb-transient--define
                                    dir (list (alist-get 'name node)) node))))
                         tree))
                groups))))
    (put sym 'bb-transient-root root)
    (put sym 'bb-transient-layers layers)
    ;; Built innermost first for the keys; shown innermost first too.
    (eval
     `(transient-define-prefix ,sym ()
        "bb tasks"
        ,@(nreverse groups)
        [("g" "Refresh" bb-transient-refresh :transient nil)])
     t)
    sym))

(defun bb-transient-refresh ()
  "Re-read bb.edn and the task specs, then reopen the menu."
  (interactive)
  (let ((root (or (get transient-current-command 'bb-transient-root)
                  (bb-transient-project))))
    (transient-setup (bb-transient--setup root t))))

;;;###autoload
(defun bb-transient ()
  "Open a transient menu of the bb tasks in the current project.
The project is the one `bb-transient-project-function' returns.
Projects named by `bb-transient-layers-functions' get groups too."
  (interactive)
  (transient-setup (bb-transient--setup (bb-transient-project))))

(provide 'bb-transient)
;;; bb-transient.el ends here
