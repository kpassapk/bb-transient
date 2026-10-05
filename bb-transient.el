;;; bb-transient.el --- Transient menus for a project's babashka tasks -*- lexical-binding: t; -*-

;; Author: Kyle Passarelli
;; URL: https://github.com/kpassapk/bb-transient
;; Version: 0.1.0
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

;;; Code:

(require 'compile)
(require 'transient)

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

(defconst bb-transient--script
  (expand-file-name "bb-transient.clj"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The introspection script that ships with this package.")

;;;; Reading the command tree

(defvar bb-transient--cache (make-hash-table :test #'equal)
  "Project root -> (MTIME . TREE).")

(defun bb-transient--root ()
  "Return the directory holding the nearest bb.edn, or signal."
  (or (locate-dominating-file default-directory "bb.edn")
      (user-error "No bb.edn in %s or above" default-directory)))

(defun bb-transient--introspect (root)
  "Run the introspection script in ROOT and return the parsed tree."
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
            (alist-get 'tasks
                       (json-parse-buffer :object-type 'alist :array-type 'list
                                          :null-object nil :false-object nil))))
      (delete-file stderr))))

(defun bb-transient--tree (root &optional refresh)
  "Return ROOT's command tree, reusing the cache unless REFRESH or bb.edn changed."
  (let* ((mtime (file-attribute-modification-time
                 (file-attributes (expand-file-name "bb.edn" root))))
         (hit (gethash root bb-transient--cache)))
    (if (and hit (not refresh) (equal (car hit) mtime))
        (cdr hit)
      (let ((tree (bb-transient--introspect root)))
        (puthash root (cons mtime tree) bb-transient--cache)
        tree))))

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
        (options (alist-get 'options node)))
    (put sym 'bb-transient-root root)
    (put sym 'bb-transient-path path)
    (put sym 'bb-transient-options options)
    (cond
     (children (bb-transient--define-menu sym root path node children))
     (options (bb-transient--define-leaf sym node options))
     (t (defalias sym
          (lambda () (interactive) (bb-transient--run root path nil))
          (alist-get 'doc node))))
    sym))

(defun bb-transient--define-menu (sym root path node children)
  "Define SYM as a menu over CHILDREN of NODE at PATH in ROOT."
  (let* ((taken (if path '("q") '("q" "g")))
         (suffixes
          (mapcar (lambda (child)
                    (let ((key (bb-transient--key (alist-get 'name child) taken)))
                      (push key taken)
                      (list key (bb-transient--describe child)
                            (bb-transient--define
                             root (append path (list (alist-get 'name child))) child))))
                  children))
         (heading (if path (concat "bb " (string-join path " ")) "bb tasks")))
    (eval
     `(transient-define-prefix ,sym ()
        ,(or (alist-get 'doc node) heading)
        [,heading ,@suffixes]
        ,@(unless path
            '([("g" "Refresh" bb-transient-refresh :transient nil)])))
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
        [,(concat heading
                  (when-let* ((doc (alist-get 'doc node)))
                    (concat "  " (propertize doc 'face 'transient-inactive-value))))
         ,@infixes
         ("-=" "Extra arguments" "++=" :prompt "Extra arguments: ")]
        [("RET" "Run" bb-transient-run-current)])
     t)))

;;;; Running

(defun bb-transient--args (args)
  "Turn transient ARGS into a bb argument list.
The `++=' extra-arguments value is split like a shell command line."
  (mapcan (lambda (a)
            (if (string-prefix-p "++=" a)
                (split-string-shell-command (substring a 3))
              (list a)))
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

(defun bb-transient--command (path args)
  "The shell command line for bb PATH with ARGS."
  (mapconcat #'shell-quote-argument
             (append (list bb-transient-program) path args)
             " "))

(defun bb-transient--run (root path args)
  "Run bb PATH with ARGS from ROOT in a compilation buffer."
  (let* ((default-directory root)
         (command (bb-transient--command path args))
         (compilation-buffer-name-function
          (lambda (_mode) (format "*bb %s*" (string-join path " ")))))
    (compile command bb-transient-use-comint)))

(transient-define-suffix bb-transient-run-current ()
  "Run the command the current menu describes."
  (interactive)
  (let* ((sym transient-current-command)
         (args (bb-transient--args (transient-args sym)))
         (missing (bb-transient--missing (get sym 'bb-transient-options) args)))
    (when missing
      (user-error "Required: %s"
                  (mapconcat (lambda (n) (concat "--" n)) missing ", ")))
    (bb-transient--run (get sym 'bb-transient-root)
                       (get sym 'bb-transient-path)
                       args)))

;;;; Entry points

(defun bb-transient--setup (root &optional refresh)
  "Define the menus for ROOT and return the top-level prefix."
  (bb-transient--define root nil
                        `((name . "bb")
                          (children . ,(bb-transient--tree root refresh)))))

(defun bb-transient-refresh ()
  "Re-read bb.edn and the task specs, then reopen the menu."
  (interactive)
  (let ((root (or (get transient-current-command 'bb-transient-root)
                  (bb-transient--root))))
    (transient-setup (bb-transient--setup root t))))

;;;###autoload
(defun bb-transient ()
  "Open a transient menu of the bb tasks in the current project."
  (interactive)
  (transient-setup (bb-transient--setup (bb-transient--root))))

(provide 'bb-transient)
;;; bb-transient.el ends here
