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
;; A command marked `:bb-transient/singleton true' runs once at a time:
;; while it is still running, running it again selects its buffer
;; instead of starting it over.
;;
;; A command marked `:bb-transient/silent true' runs without showing its
;; buffer: it pops up when the command fails or seems to ask for input,
;; and a message says when it is done.  `s' in an options menu flips it
;; for one run.
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
;; `bb-transient-layers-command' prints them.  Their commands run from
;; the current project with their own bb.edn as --config, and the
;; current project's tasks hide theirs by name.
;;
;; A layer can take part in how a command is run or copied, with
;; interceptors listed in its bb.edn:
;;
;;   :bb-transient/interceptors [forge.transient/aa]
;;
;; Picking a command makes a request, a map of what the menu decided;
;; bb-transient.clj threads it through every layer's interceptors,
;; each a pure function of the map, and builds the command line on the
;; way.  Emacs then copies the line, or runs it.  A menu whose layers
;; list none starts no process for it.

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

(defcustom bb-transient-layers-command nil
  "A program and its arguments printing the projects to show in the menu.
It runs in the current project's directory and prints the layers as
JSON, outermost first:

  [{\"name\": \"atomstream/forge\", \"root\": \"/home/me/src/forge/\"}, ...]

A relative root is taken from the current project.  Each root's bb.edn
tasks become a group headed by its name, above the current project's
own, and an inner project's task hides an outer one of the same name.
A layer whose root is the current project labels its group.  Commands
still run from the current project; see
`bb-transient-directory-function'.  The layers are also the chain of
interceptors a command goes through; see `bb-transient--final'.

Its output is cached until a bb.edn among them changes.  nil means just
the current project, or `bb-transient-layers-functions'."
  :type '(choice (const :tag "Just the project" nil)
                 (repeat :tag "Command" string)))

(defvar bb-transient-layers-functions nil
  "Functions naming other projects to show in the menu.
Used only when `bb-transient-layers-command' is nil.  Each is called
with the current project's directory and returns a list of
\(LABEL . DIRECTORY), outermost first, as the command's output.")

(make-obsolete-variable 'bb-transient-layers-functions
                        'bb-transient-layers-command "0.3.0")

(defconst bb-transient--script
  (expand-file-name "bb-transient.clj"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The introspection script that ships with this package.")

;;;; Reading the command tree

(defvar bb-transient--cache (make-hash-table :test #'equal)
  "Project root -> (MTIME . RESULT), RESULT the parsed introspection.")

(defvar bb-transient--copy nil
  "Non-nil when the next command picked is copied, not run.
Set from the top menu; cleared when the menu exits.")

(defvar project-current-directory-override)

(defun bb-transient-project-root (&optional directory)
  "The directory holding the nearest bb.edn at or above DIRECTORY, or signal.
DIRECTORY defaults to `project-current-directory-override' when that is
set, as `project-switch-project' does, else `default-directory'."
  (let ((dir (or directory
                 (bound-and-true-p project-current-directory-override)
                 default-directory)))
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
REFRESH reads it again regardless.  An alist of `tasks' and, if bb.edn
has them, `cljbang-paths' and `interceptors'."
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
  singleton non-nil when running it again while it runs switches to it
  silent    non-nil when its buffer is shown only on failure or input
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

(defun bb-transient--eval (form)
  "Evaluate FORM, a definition, leaving `current-load-list' alone.
Outside `load' nothing empties that list, and `defalias' takes time in
proportion to its length, so menus defined again on every open would
make each open slower than the last."
  (let ((current-load-list nil))
    (eval form t)))

(defun bb-transient--define (root path node)
  "Declare the command for NODE at PATH in ROOT and return its symbol.
A node with children or options becomes a transient prefix, but only
when it is first opened: until then it is a stub; see
`bb-transient--stub'.  A bare leaf becomes a command that runs
straight away."
  (let ((sym (bb-transient--sym root path))
        (terminal (alist-get 'terminal node)))
    (put sym 'bb-transient-root root)
    (put sym 'bb-transient-path path)
    (put sym 'bb-transient-node node)
    (put sym 'bb-transient-options (alist-get 'options node))
    (put sym 'bb-transient-defaults (alist-get 'defaults node))
    (put sym 'bb-transient-hooks (bb-transient--hooks root node))
    (if (or (alist-get 'children node) (alist-get 'options node))
        (bb-transient--stub sym)
      (put sym 'transient--prefix nil)
      (put sym 'bb-transient-stub nil)
      (put sym 'function-documentation (alist-get 'doc node))
      (fset sym (lambda (&optional flip)
                  (interactive "P")
                  (if bb-transient--copy
                      (bb-transient--copy root path nil node)
                    (bb-transient--run root path nil (xor terminal flip)
                                       (get sym 'bb-transient-hooks)
                                       (alist-get 'singleton node)
                                       (alist-get 'silent node)
                                       node)))))
    sym))

(defun bb-transient--stub (sym)
  "Make SYM a prefix that defines its menu the first time it is opened.
Transient tells a submenu from other suffixes by its `transient--prefix'
property, so the stub has one, and the menu still stacks on its parent."
  (put sym 'bb-transient-stub t)
  (put sym 'function-documentation
       (alist-get 'doc (get sym 'bb-transient-node)))
  (put sym 'transient--prefix (transient-prefix :command sym))
  (fset sym (lambda ()
              (interactive)
              (bb-transient--realize sym)
              (transient-setup sym))))

(defun bb-transient--realize (sym)
  "Define the menu of SYM, a command from `bb-transient--define', if it is a stub."
  (when (get sym 'bb-transient-stub)
    (put sym 'bb-transient-stub nil)
    (let ((node (get sym 'bb-transient-node)))
      (if-let* ((children (alist-get 'children node)))
          (bb-transient--define-menu sym (get sym 'bb-transient-root)
                                     (get sym 'bb-transient-path) node children)
        (bb-transient--define-leaf sym node (alist-get 'options node))))))

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
    (bb-transient--eval
     `(transient-define-prefix ,sym ()
        ,(or (alist-get 'doc node) heading)
        [,heading ,@suffixes]))))

(defun bb-transient--define-leaf (sym node options)
  "Define SYM as an options menu for leaf NODE with OPTIONS."
  (let* ((taken '("-=" "RET" "_"))
         (infixes (mapcar (lambda (opt)
                            (let ((s (bb-transient--option-suffix opt taken)))
                              (push (car s) taken)
                              s))
                          options))
         (heading (concat "bb " (string-join (get sym 'bb-transient-path) " "))))
    (bb-transient--eval
     `(transient-define-prefix ,sym ()
        ,(or (alist-get 'doc node) heading)
        ,@(when-let* ((value (append (when (alist-get 'terminal node) '("++terminal"))
                                     (when (alist-get 'silent node) '("++silent")))))
            `(:value ',value))
        :init-value #'bb-transient--init-value
        [,(concat heading
                  (when-let* ((doc (alist-get 'doc node)))
                    (concat "  " (propertize doc 'face 'transient-inactive-value))))
         ,@infixes
         ("-=" "Extra arguments" "++=" :prompt "Extra arguments: ")]
        [("RET" "Run" bb-transient-run-current)
         ("_" "Copy command" bb-transient-copy-current)
         ("t" "In a terminal" "++terminal")
         ("s" "Silently" "++silent")]))))

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
The `++=' extra-arguments value is split like a shell command line
and goes last, so options stay before any `--' it holds; the
`++terminal' and `++silent' switches are dropped."
  (let (options extra)
    (dolist (a args)
      (cond ((member a '("++terminal" "++silent")))
            ((string-prefix-p "++=" a)
             (setq extra (append extra (split-string-shell-command (substring a 3)))))
            (t (push a options))))
    (append (nreverse options) extra)))

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

(defun bb-transient--join (words)
  "The shell command line for WORDS, each quoted as need be."
  (mapconcat #'bb-transient--quote words " "))

(defun bb-transient--command (path args &optional config)
  "The shell command line for bb PATH with ARGS.
With CONFIG, a bb.edn file, pass it as --config."
  (bb-transient--join (append (list bb-transient-program)
                              (when config (list "--config" config))
                              path args)))

;; Copying a command instead of running it, for driving a workflow
;; from outside Emacs: an agent only sees commands in source blocks.

(defvar bb-transient--keep-copy nil
  "Non-nil when the next menu exit is a refresh, which keeps the copy flag.")

(defun bb-transient--clear-copy ()
  "Clear `bb-transient--copy' once no menu is left open.
A refresh closes the menu only to reopen it, so it keeps the flag."
  (cond (bb-transient--keep-copy (setq bb-transient--keep-copy nil))
        ((not transient--prefix) (setq bb-transient--copy nil))))

(add-hook 'transient-exit-hook #'bb-transient--clear-copy)

(defun bb-transient--copy (root path args &optional node)
  "Put the command line for bb PATH with ARGS in ROOT on the kill ring.
NODE is PATH's node, looked up when nil and needed.  The line is the
one the layers' interceptors make of a `copy' request, which may differ
from a run's; no before hook is called, as it can have effects.  When
an interceptor fails, the line is the one without them, and a message
says why.  Return the line."
  (let* ((request (bb-transient--request "copy" root path args node))
         why
         (words (condition-case err
                    (alist-get 'line (bb-transient--final request))
                  (error (setq why (error-message-string err))
                         (bb-transient--words request))))
         (line (bb-transient--join words)))
    (kill-new line)
    (if why
        (message "Copied, without the layers' interceptors (%s): %s" why line)
      (message "Copied: %s" line))
    line))

(defvar bb-transient--menu-directory nil
  "Where commands run from, decided when the menu opened, or nil.
Set by `bb-transient': `bb-transient-directory-function' has to be
asked while the menu's buffer and any project override are current.")

(defun bb-transient--directory (root)
  "Where to run a command from project ROOT's bb.edn.
The directory the open menu decided on, else
`bb-transient-directory-function'; ROOT when it has no answer."
  (expand-file-name
   (or bb-transient--menu-directory
       (ignore-errors (funcall bb-transient-directory-function))
       root)))

(defvar bb-transient--menu-layers nil
  "The open menu's layers, as `bb-transient--layers' returns them, or nil.")

(defun bb-transient--current-layers ()
  "The layers a command goes through: the open menu's, else the project's."
  (or bb-transient--menu-layers
      (ignore-errors (bb-transient--layers (bb-transient-project)))))

(defun bb-transient--request (mode root path args &optional node terminal silent)
  "A request for bb PATH with ARGS from ROOT's bb.edn, as an alist.
MODE is \"run\" or \"copy\".  NODE is PATH's node, if at hand.  The
keys are those of the request bb-transient.clj threads through the
layers' interceptors: see the README.  The buffer it is made in is the
origin."
  `((mode . ,mode)
    (path . ,path)
    (args . ,args)
    (root . ,(file-name-as-directory (expand-file-name root)))
    (dir . ,(file-name-as-directory (bb-transient--directory root)))
    (layers . ,(mapcar (pcase-lambda (`(,label . ,dir))
                         `((name . ,label) (root . ,dir)))
                       (bb-transient--current-layers)))
    (origin . ((file . ,(buffer-file-name)) (directory . ,default-directory)))
    (task . ,node)
    (terminal . ,terminal)
    (silent . ,silent)
    (program . ,bb-transient-program)))

(defun bb-transient--words (request)
  "The words of REQUEST's command line, as no interceptor changed them.
ROOT's bb.edn is passed as --config when the directory is not ROOT.
bb-transient.clj's `line' does the same in the chain."
  (let-alist request
    (append (list bb-transient-program)
            (unless (file-equal-p .dir .root)
              (list "--config" (expand-file-name "bb.edn" .root)))
            .path .args)))

(defun bb-transient--interceptor-roots (request)
  "The roots of REQUEST's layers whose bb.edn lists interceptors."
  (seq-keep (lambda (layer)
              (let ((root (alist-get 'root layer)))
                (and (alist-get 'interceptors (ignore-errors (bb-transient--read root)))
                     root)))
            (alist-get 'layers request)))

(defun bb-transient--json (x)
  "X, an alist from a request or a node, made fit for `json-serialize'."
  (cond ((null x) :null)
        ((and (consp x) (consp (car x)) (symbolp (caar x)))
         (let ((table (make-hash-table :test #'equal)))
           (pcase-dolist (`(,k . ,v) x)
             (puthash (symbol-name k) (bb-transient--json v) table))
           table))
        ((consp x) (vconcat (mapcar #'bb-transient--json x)))
        (t x)))

(defun bb-transient--intercept (request roots)
  "REQUEST as bb-transient.clj's `intercept' returns it, or signal.
ROOTS are the layers that list interceptors.  It runs with the first's
bb.edn as --config, so that layer's interceptors run in the same
process."
  (let ((default-directory (car roots))
        (coding-system-for-write 'utf-8)
        (coding-system-for-read 'utf-8)
        (stderr (make-temp-file "bb-transient-err")))
    (unwind-protect
        (with-temp-buffer
          (insert (json-serialize (bb-transient--json request)))
          (let ((status (call-process-region
                         (point-min) (point-max) bb-transient-program t (list t stderr) nil
                         "--config" (expand-file-name "bb.edn" (car roots))
                         "-f" bb-transient--script "intercept")))
            (unless (eql status 0)
              (error "%s" (let ((msg (with-temp-buffer
                                       (insert-file-contents stderr)
                                       (string-trim (buffer-string)))))
                            (if (string-empty-p msg) (format "bb exited %s" status) msg))))
            ;; Namespaces may print as they load; the JSON is the last line.
            (goto-char (point-max))
            (forward-line -1)
            (json-parse-buffer :object-type 'alist :array-type 'list
                               :null-object nil :false-object nil)))
      (delete-file stderr))))

(defun bb-transient--final (request)
  "REQUEST as the layers' interceptors leave it, or signal if one fails.
When a layer lists interceptors, bb-transient.clj runs them: every
:enter, outermost layer first, then the `line' step, then every :leave
the other way.  Otherwise it only gets its line, here.  Emacs reads
`mode', `line', `dir', `terminal' and `silent' from the result; a
copy stays a copy."
  (if-let* ((roots (bb-transient--interceptor-roots request)))
      (let* ((request (if (alist-get 'task request)
                          request
                        (let-alist request
                          (cons (cons 'task (ignore-errors (bb-transient--node .root .path)))
                                request))))
             (final (bb-transient--intercept request roots)))
        (if (equal (alist-get 'mode request) "copy")
            (cons '(mode . "copy") final)
          final))
    (cons (cons 'line (bb-transient--words request)) request)))

(defun bb-transient--buffer-name (path)
  "The name of the output buffer for bb PATH."
  (format "*bb %s*" (string-join path " ")))

(defun bb-transient--node (root path)
  "The node for PATH in ROOT's tasks, or nil."
  (let ((nodes (bb-transient-tasks root))
        node)
    (while (and path
                (setq node (seq-find (lambda (n) (equal (alist-get 'name n) (car path)))
                                     nodes)))
      (setq nodes (alist-get 'children node)
            path (cdr path)))
    (and (not path) node)))

(defun bb-transient--running (path)
  "The output buffer for bb PATH if its process is still running, or nil."
  (when-let* ((buf (get-buffer (bb-transient--buffer-name path)))
              (proc (get-buffer-process buf)))
    (and (process-live-p proc) buf)))

(defconst bb-transient--prompt-delay 0.3
  "Seconds a silent command's last, unfinished line must stand to be a prompt.")

(defun bb-transient--silence (buf path)
  "Keep BUF, a silent run of bb PATH, out of sight unless it needs you.
It is shown when the command exits non-zero, or when it has written a
line with no newline and nothing more for `bb-transient--prompt-delay'
seconds while still running: probably a prompt.  An exit of 0 is only
a message."
  (when-let* ((proc (get-buffer-process buf)))
    (let ((name (string-join path " "))
          timer)
      (add-function
       :after (process-filter proc)
       (lambda (proc string)
         (when timer (cancel-timer timer) (setq timer nil))
         (unless (or (string-suffix-p "\n" string)
                     (get-buffer-window buf t))
           (setq timer
                 (run-at-time bb-transient--prompt-delay nil
                              (lambda ()
                                (setq timer nil)
                                (when (process-live-p proc)
                                  (display-buffer buf)
                                  (message "bb %s is waiting for input" name))))))))
      ;; Added before the after hook's, so it runs first: the hook's own
      ;; messages and windows win.
      (add-function
       :after (process-sentinel proc)
       (lambda (proc _event)
         (unless (process-live-p proc)
           (when timer (cancel-timer timer))
           (if (eql (process-exit-status proc) 0)
               (message "bb %s: done" name)
             (setq next-error-last-buffer buf)
             (display-buffer buf))))))))

(defun bb-transient--run (root path args &optional terminal hooks singleton silent node)
  "Run bb PATH with ARGS, using ROOT's bb.edn, and return the output buffer.
It runs from `bb-transient--directory', passing ROOT's bb.edn as
--config when that is not ROOT.  The buffer is a compilation buffer,
or with TERMINAL an interactive `ghostel-compile' buffer, so TUIs get
a real terminal.

With SILENT, and no TERMINAL, the buffer is not shown unless the
command fails or asks for input; see `bb-transient--silence'.

With SINGLETON, when PATH is still running from an earlier call,
select its buffer and return it instead: nothing is started, ARGS are
ignored and no hook is called.

HOOKS, from `bb-transient--hooks', are called here: before with the
args and directory, which may return new args, and after once the
process exits.  A before hook that signals cancels the run, and
returns nil.

The command then goes through the layers' interceptors as a `run'
request (see `bb-transient--final'), NODE being PATH's node if at hand.
They decide the line, the directory, TERMINAL and SILENT, or that it is
copied instead, which returns nil.  When one fails nothing runs, and
nil is returned."
  (if-let* ((buf (and singleton (bb-transient--running path))))
      (progn
        (pop-to-buffer buf)
        (message "bb %s is already running" (string-join path " "))
        buf)
    (bb-transient--start root path args terminal hooks silent node)))

(defun bb-transient--start (root path args terminal hooks silent &optional node)
  "Start bb PATH with ARGS for `bb-transient--run', which see.
ROOT, TERMINAL, HOOKS, SILENT and NODE are as there."
  (let* ((hooks (bb-transient--usable-hooks hooks path))
         (origin (current-buffer))
         (args (condition-case err
                   (if-let* ((new (bb-transient--call-hook
                                   hooks 'before (list :args (vconcat args)
                                                       :dir (bb-transient--directory root)))))
                       (append new nil)
                     args)
                 (error (message "bb-transient: before hook, not running: %s"
                                 (bb-transient--error-message err))
                        'cancel)))
         (final (unless (eq args 'cancel)
                  (condition-case err
                      (bb-transient--final
                       (bb-transient--request "run" root path args node terminal silent))
                    (error (message "bb-transient: not running bb %s: %s"
                                    (string-join path " ") (error-message-string err))
                           nil)))))
    (cond
     ((null final) nil)
     ((equal (alist-get 'mode final) "copy")
      (let ((line (bb-transient--join (alist-get 'line final))))
        (kill-new line)
        (message "Copied: %s" line)
        nil))
     (t
      (let* ((default-directory (file-name-as-directory (alist-get 'dir final)))
             (terminal (alist-get 'terminal final))
             (silent (alist-get 'silent final))
             (command (bb-transient--join (alist-get 'line final)))
             (name (bb-transient--buffer-name path))
             (buf (if terminal
                      (progn
                        (unless (require 'ghostel-compile nil t)
                          (user-error "Running in a terminal needs the ghostel package"))
                        (let ((ghostel-compile-buffer-name name))
                          (ghostel-compile command t)))
                    (let ((compilation-buffer-name-function (lambda (_mode) name)))
                      (if (not silent)
                          (compile command bb-transient-use-comint)
                        ;; `compile' asks for a window with `allow-no-window'.
                        (let ((display-buffer-overriding-action
                               '(display-buffer-no-window (allow-no-window . t)))
                              (last next-error-last-buffer))
                          (prog1 (compile command bb-transient-use-comint)
                            ;; Leave `next-error' with what you can see.
                            (setq next-error-last-buffer last))))))))
        (when (and silent (not terminal))
          (bb-transient--silence buf path))
        (when (alist-get 'after hooks)
          ;; The process can't have written yet: its filter only runs
          ;; once Emacs waits.  A terminal's output is its whole text.
          (bb-transient--watch buf (unless terminal (with-current-buffer buf (point-max)))
                               args hooks origin))
        buf)))))

(defun bb-transient-command-line (path &optional args project)
  "The shell command line for bb task PATH (a list of names) with ARGS.
PROJECT is the directory whose bb.edn defines the task; nil means the
current project.  It is the line a run would use, interceptors
included, and signals when one fails.  Nothing is run, and no before
hook is called.  For your own glue, such as an org block or a message
to an agent."
  (let ((bb-transient--menu-directory nil)
        (bb-transient--menu-layers nil))
    (bb-transient--join
     (alist-get 'line (bb-transient--final
                       (bb-transient--request "run" (or project (bb-transient-project))
                                              path args))))))

(defun bb-transient-run (path &optional args project terminal silent)
  "Run bb task PATH (a list of names) with ARGS and return its buffer.
PROJECT is the directory whose bb.edn defines the task; nil means the
current project.  It runs from `bb-transient-directory-function', in
a compilation buffer, or with TERMINAL a `ghostel-compile' one.  With
SILENT the compilation buffer is shown only if the command fails or
asks for input.  A task marked `:bb-transient/singleton' that is still
running is switched to instead."
  (let ((bb-transient--menu-directory nil)
        (bb-transient--menu-layers nil)
        (root (or project (bb-transient-project))))
    (bb-transient--run root path args terminal nil
                       ;; Only a task that may be running needs looking up.
                       (and (bb-transient--running path)
                            (alist-get 'singleton
                                       (ignore-errors (bb-transient--node root path))))
                       silent)))

(defun bb-transient--current-args ()
  "The current options menu's bb arguments, or signal if one is missing."
  (let* ((sym transient-current-command)
         (args (bb-transient--args (transient-args sym)))
         (missing (bb-transient--missing (get sym 'bb-transient-options) args)))
    (when missing
      (user-error "Required: %s"
                  (mapconcat (lambda (n) (concat "--" n)) missing ", ")))
    args))

(transient-define-suffix bb-transient-run-current ()
  "Run the command the current menu describes.
When the top menu asked for copying, copy it instead."
  (interactive)
  (if bb-transient--copy
      (bb-transient-copy-current)
    (let* ((sym transient-current-command)
           (value (transient-args sym)))
      (bb-transient--run (get sym 'bb-transient-root)
                         (get sym 'bb-transient-path)
                         (bb-transient--current-args)
                         (member "++terminal" value)
                         (get sym 'bb-transient-hooks)
                         (alist-get 'singleton (get sym 'bb-transient-node))
                         (member "++silent" value)
                         (get sym 'bb-transient-node)))))

(transient-define-suffix bb-transient-copy-current ()
  "Copy the command line `bb-transient-run-current' would run.
The before hook is not called."
  (interactive)
  (let ((sym transient-current-command))
    (bb-transient--copy (get sym 'bb-transient-root)
                        (get sym 'bb-transient-path)
                        (bb-transient--current-args)
                        (get sym 'bb-transient-node))))

(transient-define-suffix bb-transient-toggle-copy ()
  "Copy the next command picked instead of running it."
  :transient t
  :description (lambda () (format "Copy instead of run: %s"
                                  (if bb-transient--copy "on" "off")))
  (interactive)
  (setq bb-transient--copy (not bb-transient--copy)))

;;;; Entry points

(defvar bb-transient--layers-cache (make-hash-table :test #'equal)
  "Project root -> (MTIMES . LAYERS), from `bb-transient-layers-command'.")

(defun bb-transient--mtimes (dirs)
  "The modification times of the bb.edn in each of DIRS."
  (mapcar (lambda (dir)
            (file-attribute-modification-time
             (file-attributes (expand-file-name "bb.edn" dir))))
          dirs))

(defun bb-transient--layers-command-output (root)
  "Run `bb-transient-layers-command' in ROOT; its layers, as (LABEL . DIR)."
  (let ((default-directory root)
        (stderr (make-temp-file "bb-transient-err")))
    (unwind-protect
        (with-temp-buffer
          (let ((status (apply #'call-process (car bb-transient-layers-command)
                               nil (list t stderr) nil (cdr bb-transient-layers-command))))
            (unless (eql status 0)
              (error "exit %s: %s" status
                     (with-temp-buffer
                       (insert-file-contents stderr)
                       (string-trim (buffer-string)))))
            (goto-char (point-max))
            (forward-line -1)
            (mapcar (lambda (layer)
                      (cons (alist-get 'name layer)
                            (expand-file-name (alist-get 'root layer) root)))
                    (json-parse-buffer :object-type 'alist :array-type 'list
                                       :null-object nil :false-object nil))))
      (delete-file stderr))))

(defun bb-transient--layers-from-command (root refresh)
  "The layers `bb-transient-layers-command' prints for ROOT, cached.
The cache holds until ROOT's bb.edn or one of the layers' changes, or
REFRESH."
  (let ((hit (gethash root bb-transient--layers-cache)))
    (if (and hit (not refresh)
             (equal (car hit) (bb-transient--mtimes (cons root (mapcar #'cdr (cdr hit))))))
        (cdr hit)
      (let ((layers (bb-transient--layers-command-output root)))
        (puthash root (cons (bb-transient--mtimes (cons root (mapcar #'cdr layers))) layers)
                 bb-transient--layers-cache)
        layers))))

(defun bb-transient--layers (root &optional refresh)
  "The projects in ROOT's menu as (LABEL . DIRECTORY), outermost first.
They come from `bb-transient-layers-command', or when that is nil
from `bb-transient-layers-functions'.  The last is ROOT, labelled by
its directory name unless the command or a function labels it.
REFRESH runs the command again."
  (let ((root (file-name-as-directory (expand-file-name root)))
        found layers)
    (if bb-transient-layers-command
        (condition-case err
            (setq found (bb-transient--layers-from-command root refresh))
          (error (message "bb-transient: %s failed: %s"
                          (string-join bb-transient-layers-command " ")
                          (error-message-string err))))
      (with-suppressed-warnings ((obsolete bb-transient-layers-functions))
        (run-hook-wrapped
         'bb-transient-layers-functions
         (lambda (fn)
           (condition-case err
               (setq found (append found (funcall fn root)))
             (error (message "bb-transient: %s failed: %s" fn (error-message-string err))))
           nil))))
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
outermost layer first, so a parent's keys are the same in every project
that uses it; ROOT's tasks take what is left.  A task in an inner layer
hides an outer layer's of the same name.  A layer whose tasks can't be
read is left out, unless it is ROOT.  REFRESH also recompiles the
defaults and hooks, and requires hook namespaces again.

The menu is only defined again when the layers or what was read of
them changed, or on REFRESH.  Its submenus are defined when first
opened; see `bb-transient--define'."
  (when refresh
    (clrhash bb-transient--compiled)
    (clrhash bb-transient--required))
  (let* ((root (file-name-as-directory (expand-file-name root)))
         (layers (bb-transient--layers root refresh))
         (sym (intern (format "bb-transient:%s"
                              (substring (md5 (prin1-to-string layers)) 0 6))))
         (taken (list "q" "g" "_"))
         seen found groups read)
    ;; Innermost first, so its tasks hide an outer layer's; `found' ends
    ;; up outermost first, which is the order the keys are given in.
    (pcase-dolist (`(,label . ,dir) (reverse layers))
      (when-let* ((result (condition-case err
                              (bb-transient--read dir refresh)
                            (error (if (file-equal-p dir root)
                                       (signal (car err) (cdr err))
                                     (message "bb-transient: skipping %s: %s"
                                              label (error-message-string err))
                                     nil))))
                  (tree (alist-get 'tasks result)))
        (push (cons dir result) read)
        (let ((tree (seq-remove (lambda (n) (member (alist-get 'name n) seen)) tree)))
          ;; Ask now, not while a menu is up.
          (when (and (bb-transient--has-forms tree) (bb-transient--cljbang-p))
            (bb-transient--trusted-p dir))
          (setq seen (append seen (mapcar (lambda (n) (alist-get 'name n)) tree)))
          (push (list label dir tree) found))))
    (let ((built (cons layers read)))
      (unless (and (not refresh)
                   (get sym 'transient--prefix)
                   (equal built (get sym 'bb-transient-built)))
        ;; Pushing reverses `found', so the groups end up innermost first.
        (pcase-dolist (`(,label ,dir ,tree) found)
          (push (vconcat
                 (list (if (cdr layers) label "bb tasks"))
                 (mapcar (lambda (node)
                           (let ((key (bb-transient--key (alist-get 'name node) taken)))
                             (push key taken)
                             (list key (bb-transient--describe node)
                                   (bb-transient--define
                                    dir (list (alist-get 'name node)) node))))
                         tree))
                groups))
        (put sym 'bb-transient-root root)
        (put sym 'bb-transient-layers layers)
        (bb-transient--eval
         `(transient-define-prefix ,sym ()
            "bb tasks"
            ,@groups
            [("g" "Refresh" bb-transient-refresh :transient nil)
             ("_" bb-transient-toggle-copy)]))
        (put sym 'bb-transient-built built)))
    sym))

(defun bb-transient-refresh ()
  "Re-read bb.edn and the task specs, then reopen the menu."
  (interactive)
  (let ((root (or (get transient-current-command 'bb-transient-root)
                  (bb-transient-project))))
    (setq bb-transient--keep-copy bb-transient--copy)
    (let ((sym (bb-transient--setup root t)))
      (setq bb-transient--menu-layers (get sym 'bb-transient-layers))
      (transient-setup sym))))

;;;###autoload
(defun bb-transient ()
  "Open a transient menu of the bb tasks in the current project.
The project is the one `bb-transient-project-function' returns.
Projects named by `bb-transient-layers-command' get groups too."
  (interactive)
  (let ((sym (bb-transient--setup (bb-transient-project))))
    (setq bb-transient--keep-copy nil
          bb-transient--menu-layers (get sym 'bb-transient-layers)
          bb-transient--menu-directory
          (ignore-errors (funcall bb-transient-directory-function)))
    (transient-setup sym)))

(provide 'bb-transient)
;;; bb-transient.el ends here
