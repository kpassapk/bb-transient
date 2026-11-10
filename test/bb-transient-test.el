;;; bb-transient-test.el --- Tests for bb-transient -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'org)
(require 'bb-transient)

(defconst bb-transient-test--fixture
  (file-name-as-directory
   (expand-file-name "fixture"
                     (file-name-directory (or load-file-name buffer-file-name)))))

(defconst bb-transient-test--outer
  (file-name-as-directory
   (expand-file-name "../outer" bb-transient-test--fixture)))

;; The fixture's forms are ours; never prompt in batch.
(setq bb-transient-eval-hooks t)

(defun bb-transient-test--wait (buf)
  (while (get-buffer-process buf) (accept-process-output nil 0.1))
  (with-current-buffer buf (buffer-string)))

(defun bb-transient-test--find (name nodes)
  (seq-find (lambda (n) (equal (alist-get 'name n) name)) nodes))

;;;; Introspection (needs bb on PATH)

(ert-deftest bb-transient-test-tree-order-and-privacy ()
  (let ((tree (bb-transient-tasks bb-transient-test--fixture t)))
    (should (equal (mapcar (lambda (n) (alist-get 'name n)) tree)
                   '("zeta" "greet" "echo" "broken" "table" "tui" "hooks" "noted")))))

(ert-deftest bb-transient-test-tree-specs ()
  (let* ((tree (bb-transient-tasks bb-transient-test--fixture t))
         (greet (bb-transient-test--find "greet" tree))
         (hello (bb-transient-test--find "hello" (alist-get 'children greet)))
         (opts (alist-get 'options hello)))
    (should (equal (alist-get 'doc hello) "Say hello to someone"))
    (should (equal (mapcar (lambda (o) (alist-get 'name o)) opts)
                   '("name" "loud" "times")))
    (let ((name (bb-transient-test--find "name" opts)))
      (should (equal (alist-get 'alias name) "n"))
      (should (eq (alist-get 'require name) t)))
    (should (alist-get 'boolean (bb-transient-test--find "loud" opts)))
    (should (equal (alist-get 'default (bb-transient-test--find "times" opts)) 1))
    ;; A vector spec keeps its order too.
    (should (equal (mapcar (lambda (o) (alist-get 'name o))
                           (alist-get 'options (bb-transient-test--find "echo" tree)))
                   '("a" "b")))
    ;; Nested :cmd tables become nested children.
    (should (bb-transient-test--find
             "deep" (alist-get 'children
                               (bb-transient-test--find
                                "nested" (alist-get 'children greet)))))))

(ert-deftest bb-transient-test-tree-unresolved ()
  (let ((broken (bb-transient-test--find
                 "broken" (bb-transient-tasks bb-transient-test--fixture t))))
    (should (string-match-p "cmds/nope" (alist-get 'error broken)))))

(ert-deftest bb-transient-test-setup-defines-menus ()
  (let* ((root bb-transient-test--fixture)
         (top (bb-transient--setup root t))
         (hello (bb-transient--sym root '("greet" "hello")))
         (deep (bb-transient--sym root '("greet" "nested" "deep"))))
    (should (get top 'transient--prefix))
    (should (get hello 'transient--prefix))
    (should (equal (get hello 'bb-transient-path) '("greet" "hello")))
    ;; A leaf without options is a plain command, not a menu.
    (should (commandp deep))
    (should-not (get deep 'transient--prefix))))

;; `:cmd some/var' names a var holding the table.
(ert-deftest bb-transient-test-tree-cmd-var ()
  (let* ((table (bb-transient-test--find
                 "table" (bb-transient-tasks bb-transient-test--fixture t)))
         (echo (bb-transient-test--find "echo" (alist-get 'children table))))
    (should-not (alist-get 'error table))
    (should (equal (alist-get 'doc echo) "Print the parsed options"))
    (should (equal (mapcar (lambda (o) (alist-get 'name o))
                           (alist-get 'options echo))
                   '("a" "b")))))

;; `:bb-transient/terminal' on the fn or in the task map marks a TUI.
(ert-deftest bb-transient-test-tree-terminal ()
  (let ((tui (alist-get 'children
                        (bb-transient-test--find
                         "tui" (bb-transient-tasks bb-transient-test--fixture t)))))
    (should (eq (alist-get 'terminal (bb-transient-test--find "top" tui)) t))
    (should (eq (alist-get 'terminal (bb-transient-test--find "watch" tui)) t))
    (should-not (alist-get 'terminal (bb-transient-test--find "plain" tui)))))

(ert-deftest bb-transient-test-setup-terminal-default ()
  (let* ((root bb-transient-test--fixture)
         (_ (bb-transient--setup root t))
         (watch (bb-transient--sym root '("tui" "watch")))
         (echo (bb-transient--sym root '("echo"))))
    (should (equal (oref (get watch 'transient--prefix) default-value) '("++terminal")))
    (should-not (slot-boundp (get echo 'transient--prefix) 'default-value))))

;;;; Pure helpers

(ert-deftest bb-transient-test-key ()
  (should (equal (bb-transient--key "work" '()) "w"))
  (should (equal (bb-transient--key "work" '("w")) "o"))
  (should (equal (bb-transient--key "test-pod" '("t" "e" "s")) "p"))
  (should (equal (bb-transient--key "dry-run" '("-d") "-") "-r"))
  (should (equal (bb-transient--key "ab" '("a" "b")) "A")))

(ert-deftest bb-transient-test-option-suffix ()
  (should (equal (bb-transient--option-suffix
                  '((name . "loud") (desc . "Shout") (boolean . t)) '())
                 '("-l" "Shout" "--loud")))
  (should (equal (car (bb-transient--option-suffix
                       '((name . "name") (alias . "n")) '()))
                 "-n"))
  ;; A taken alias falls back to the name's letters.
  (should (equal (car (bb-transient--option-suffix
                       '((name . "name") (alias . "n")) '("-n")))
                 "-a"))
  (should (equal (nth 2 (bb-transient--option-suffix '((name . "title")) '()))
                 "--title=")))

(ert-deftest bb-transient-test-args ()
  (should (equal (bb-transient--args '("--title=A b" "++=--x 1 \"two words\""))
                 '("--title=A b" "--x" "1" "two words")))
  (should (equal (bb-transient--args '("++terminal" "--a=1")) '("--a=1"))))

(ert-deftest bb-transient-test-missing ()
  (let ((opts '(((name . "title") (require . t))
                ((name . "force") (require . t))
                ((name . "tags")))))
    (should (equal (bb-transient--missing opts '("--title=x")) '("force")))
    (should (equal (bb-transient--missing opts '("--title=x" "--force")) nil))))

(ert-deftest bb-transient-test-command ()
  (let ((bb-transient-program "bb"))
    (should (equal (bb-transient--command '("greet") '("--lang=zh" "--name=Alice"))
                   "bb greet --lang=zh --name=Alice"))
    (should (equal (bb-transient--command '("work" "new") '("--title=A b"))
                   "bb work new --title\\=A\\ b"))
    (should (equal (bb-transient--command '("x") '("--v=$HOME;rm"))
                   "bb x --v\\=\\$HOME\\;rm"))))

(ert-deftest bb-transient-test-command-config ()
  (let ((bb-transient-program "bb"))
    (should (equal (bb-transient--command '("hi") nil "/a/bb.edn")
                   "bb --config /a/bb.edn hi"))))

(ert-deftest bb-transient-test-run-end-to-end ()
  (let* ((bb-transient-use-comint nil)
         (default-directory bb-transient-test--fixture)
         (buf (bb-transient-run '("greet" "hello") '("--name=ert" "--loud"))))
    (with-current-buffer buf
      (while (get-buffer-process buf) (accept-process-output nil 0.1))
      (should (string-match-p "HELLO ERT" (buffer-string))))
    (kill-buffer buf)))

(ert-deftest bb-transient-test-run-from-another-project ()
  ;; A menu built from the fixture, opened from another project, runs
  ;; there with the fixture's bb.edn as --config.
  (let* ((bb-transient-use-comint nil)
         (other (file-name-as-directory (make-temp-file "bb-transient-other" t)))
         (default-directory other))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "bb.edn" other) (insert "{}"))
          (let ((buf (bb-transient-run '("greet" "hello") '("--name=ert")
                                       bb-transient-test--fixture)))
            (with-current-buffer buf
              (while (get-buffer-process buf) (accept-process-output nil 0.1))
              (should (file-equal-p default-directory other))
              (should (string-match-p "--config" (buffer-string)))
              (should (string-match-p "hello ert" (buffer-string))))
            (kill-buffer buf)))
      (delete-directory other t))))

(ert-deftest bb-transient-test-directory-function ()
  ;; Run from the buffer's own directory, below the project root.
  (let* ((bb-transient-use-comint nil)
         (bb-transient-directory-function (lambda () default-directory))
         (default-directory (expand-file-name "bb/" bb-transient-test--fixture))
         (buf (bb-transient-run '("greet" "hello") '("--name=ert"))))
    (let ((out (bb-transient-test--wait buf)))
      (should (string-match-p "--config" out))
      (should (string-match-p "hello ert" out)))
    (with-current-buffer buf
      (should (file-equal-p default-directory
                            (expand-file-name "bb/" bb-transient-test--fixture))))
    (kill-buffer buf)))

(defvar project-current-directory-override)

(ert-deftest bb-transient-test-project-switch ()
  ;; `project-switch-project' binds the override around the command;
  ;; the menu is for that project, and runs from it after the override
  ;; is gone.
  (let* ((bb-transient-use-comint nil)
         (other (file-name-as-directory (make-temp-file "bb-transient-other" t)))
         (default-directory other)
         opened)
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "bb.edn" other) (insert "{}"))
          (cl-letf (((symbol-function 'transient-setup)
                     (lambda (sym &rest _) (setq opened sym))))
            (let ((project-current-directory-override bb-transient-test--fixture))
              (should (file-equal-p (bb-transient-project-root)
                                    bb-transient-test--fixture))
              (bb-transient)))
          (should (file-equal-p (get opened 'bb-transient-root)
                                bb-transient-test--fixture))
          (let ((buf (bb-transient--run bb-transient-test--fixture
                                        '("greet" "hello") '("--name=ert"))))
            (let ((out (bb-transient-test--wait buf)))
              (should-not (string-match-p "--config" out))
              (should (string-match-p "hello ert" out)))
            (with-current-buffer buf
              (should (file-equal-p default-directory bb-transient-test--fixture)))
            (kill-buffer buf)))
      (setq bb-transient--menu-directory nil)
      (delete-directory other t))))

;;;; Defaults from point

(defmacro bb-transient-test--in-task (&rest body)
  "Run BODY in an Org buffer whose entry has an :ID:."
  (declare (indent 0))
  `(with-temp-buffer
     (rename-buffer "task.org" t)
     (org-mode)
     (insert "* Task\n:PROPERTIES:\n:ID:       ABC-123\n:END:\n** Sub\n")
     (let ((bb-transient-eval-hooks t))
       ,@body)))

(defun bb-transient-test--leaf (path)
  (let ((node (cons nil (list (cons 'children
                                    (bb-transient-tasks bb-transient-test--fixture))))))
    (dolist (name path node)
      (setq node (bb-transient-test--find name (alist-get 'children node))))))

(ert-deftest bb-transient-test-tree-defaults ()
  (bb-transient-tasks bb-transient-test--fixture t)
  ;; bb.edn's forms, only for options the leaf has.
  (should (equal (alist-get 'defaults (bb-transient-test--leaf '("echo")))
                 '((a . "(el/org-entry-get nil \"ID\" true)")
                   (b . "(el/error \"Boom\")"))))
  ;; The :exec-fn's metadata adds to them, and the task map replaces them.
  (should (equal (alist-get 'defaults (bb-transient-test--leaf '("greet" "hello")))
                 '((name . "(el/buffer-name)")
                   (loud . "(el/derived-mode-p (quote org-mode))"))))
  (should (equal (alist-get 'a (alist-get 'defaults (bb-transient-test--leaf '("tui" "watch"))))
                 "(el/buffer-name)"))
  ;; No options, no defaults.
  (should-not (alist-get 'defaults (bb-transient-test--leaf '("greet" "nested" "deep")))))

(ert-deftest bb-transient-test-fill ()
  (skip-unless (require 'cljbang nil t))
  (bb-transient-tasks bb-transient-test--fixture t)
  (bb-transient-test--in-task
    (let ((echo (bb-transient-test--leaf '("echo")))
          (hello (bb-transient-test--leaf '("greet" "hello"))))
      ;; :ID: is inherited; the form that signals leaves --b out.
      (should (equal (bb-transient--fill bb-transient-test--fixture
                                         (alist-get 'options echo)
                                         (alist-get 'defaults echo))
                     '("--a=ABC-123")))
      ;; A switch is set when its form is non-nil.
      (should (equal (bb-transient--fill bb-transient-test--fixture
                                         (alist-get 'options hello)
                                         (alist-get 'defaults hello))
                     (list (concat "--name=" (buffer-name)) "--loud")))
      (fundamental-mode)
      (should (equal (bb-transient--fill bb-transient-test--fixture
                                         (alist-get 'options hello)
                                         (alist-get 'defaults hello))
                     (list (concat "--name=" (buffer-name))))))))

(ert-deftest bb-transient-test-fill-eval-hooks ()
  (skip-unless (require 'cljbang nil t))
  (bb-transient-tasks bb-transient-test--fixture t)
  (bb-transient-test--in-task
    (let* ((echo (bb-transient-test--leaf '("echo")))
           (fill (lambda ()
                   (bb-transient--fill bb-transient-test--fixture
                                       (alist-get 'options echo)
                                       (alist-get 'defaults echo))))
           (asked 0))
      (let ((bb-transient-eval-hooks nil))
        (should-not (funcall fill)))
      ;; `ask' asks once per project.
      (let ((bb-transient-eval-hooks 'ask)
            (bb-transient--trust (make-hash-table :test #'equal)))
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) (cl-incf asked) nil)))
          (should-not (funcall fill))
          (should-not (funcall fill))
          (should (= asked 1)))))))

(ert-deftest bb-transient-test-init-value ()
  (skip-unless (require 'cljbang nil t))
  (let* ((root bb-transient-test--fixture)
         (_ (bb-transient--setup root t))
         (echo (bb-transient--sym root '("echo")))
         (watch (bb-transient--sym root '("tui" "watch")))
         (value (lambda (sym)
                  (let ((obj (clone (get sym 'transient--prefix))))
                    (bb-transient--init-value obj)
                    (oref obj value)))))
    (bb-transient-test--in-task
      (goto-char (point-max))
      ;; The filled value replaces a saved one; other saved args stay.
      (let ((transient-values `((,echo "--a=old" "--b=kept"))))
        (should (equal (funcall value echo) '("--b=kept" "--a=ABC-123"))))
      ;; The terminal preset stays.
      (should (equal (funcall value watch)
                     (list "++terminal" (concat "--a=" (buffer-name))))))))

(ert-deftest bb-transient-test-project-function ()
  (let* ((bb-transient-use-comint nil)
         (other (file-name-as-directory (make-temp-file "bb-transient-other" t)))
         (default-directory other)
         (bb-transient-project-function (lambda () bb-transient-test--fixture)))
    (unwind-protect
        (progn
          (should (file-equal-p (bb-transient-project) bb-transient-test--fixture))
          ;; Commands run from that project too, with no bb.edn here.
          (let* ((buf (bb-transient-run '("greet" "hello") '("--name=ert")))
                 (out (bb-transient-test--wait buf)))
            (should-not (string-match-p "--config" out))
            (should (string-match-p "hello ert" out))
            (with-current-buffer buf
              (should (file-equal-p default-directory bb-transient-test--fixture)))
            (kill-buffer buf)))
      (delete-directory other t))))

;;;; Hooks

(defvar bb-transient-test--after nil
  "What fixture.hooks/record last saw.")

(ert-deftest bb-transient-test-tree-hooks ()
  (bb-transient-tasks bb-transient-test--fixture t)
  ;; In the task map, and quoted on the :exec-fn's metadata.
  (should (equal (alist-get 'before (bb-transient-test--leaf '("hooks" "rewrite")))
                 "(fn [{:keys [args]}] (conj args \"--b=added\"))"))
  (should (equal (alist-get 'after (bb-transient-test--leaf '("hooks" "record")))
                 "fixture.hooks/record"))
  ;; A plain :task can have one too.
  (should (equal (alist-get 'after (bb-transient-test--leaf '("noted")))
                 "fixture.hooks/record"))
  (should-not (alist-get 'before (bb-transient-test--leaf '("echo"))))
  (should (equal (bb-transient--cljbang-paths bb-transient-test--fixture)
                 (list (expand-file-name "emacs" bb-transient-test--fixture)))))

(defun bb-transient-test--run-hooked (path args)
  "Run fixture command PATH with ARGS and its hooks, as its menu would."
  (let* ((root bb-transient-test--fixture)
         (_ (bb-transient--setup root t))
         (bb-transient-use-comint nil)
         (default-directory root))
    (bb-transient--run root path args nil
                       (get (bb-transient--sym root path) 'bb-transient-hooks))))

(ert-deftest bb-transient-test-before-rewrites-args ()
  (skip-unless (require 'cljbang nil t))
  (let* ((buf (bb-transient-test--run-hooked '("hooks" "rewrite") '("--a=x")))
         (out (bb-transient-test--wait buf)))
    (should (string-match-p ":b \"added\"" out))
    (kill-buffer buf)))

(ert-deftest bb-transient-test-before-cancels ()
  (skip-unless (require 'cljbang nil t))
  (should-not (bb-transient-test--run-hooked '("hooks" "refuse") nil))
  (should-not (get-buffer "*bb hooks refuse*")))

(ert-deftest bb-transient-test-after ()
  (skip-unless (require 'cljbang nil t))
  (setq bb-transient-test--after nil)
  (with-temp-buffer
    (rename-buffer "origin" t)
    (let* ((buf (bb-transient-test--run-hooked '("hooks" "record") '("--msg=hi")))
           (_ (bb-transient-test--wait buf))
           (m bb-transient-test--after))
      (should (hash-table-p m))
      ;; Runs on failure too, in the buffer the menu was opened from.
      (should (equal (gethash :exit m) 2))
      (should (equal (gethash :out m) "hi\n"))
      (should (eq (gethash :buffer m) buf))
      (should (equal (gethash :args m) ["--msg=hi"]))
      (should (equal (gethash :in m) (buffer-name)))
      (kill-buffer buf))))

(ert-deftest bb-transient-test-after-plain-task ()
  (skip-unless (require 'cljbang nil t))
  (setq bb-transient-test--after nil)
  (let ((buf (bb-transient-test--run-hooked '("noted") nil)))
    (bb-transient-test--wait buf)
    (should (equal (gethash :exit bb-transient-test--after) 0))
    (should (equal (gethash :out bb-transient-test--after) "noted\n"))
    (kill-buffer buf)))

(ert-deftest bb-transient-test-hooks-untrusted ()
  (skip-unless (require 'cljbang nil t))
  (setq bb-transient-test--after nil)
  ;; The command still runs, without its hooks.
  (let* ((bb-transient-eval-hooks nil)
         (buf (bb-transient-test--run-hooked '("noted") nil)))
    (should (string-match-p "^noted$" (bb-transient-test--wait buf)))
    (should-not bb-transient-test--after)
    (kill-buffer buf)))

;;;; Layers

(defun bb-transient-test--outer-layer (_root)
  (list (cons "outer" bb-transient-test--outer)))

(ert-deftest bb-transient-test-layers ()
  (let ((bb-transient-layers-functions '(bb-transient-test--outer-layer)))
    (should (equal (mapcar #'car (bb-transient--layers bb-transient-test--fixture))
                   '("outer" "fixture"))))
  ;; A function may label the current project, and duplicates collapse.
  (let ((bb-transient-layers-functions
         (list (lambda (root)
                 (list (cons "o1" bb-transient-test--outer)
                       (cons "o2" bb-transient-test--outer)
                       (cons "me" root))))))
    (should (equal (mapcar #'car (bb-transient--layers bb-transient-test--fixture))
                   '("o2" "me")))))

(ert-deftest bb-transient-test-layers-failing-function ()
  (let ((bb-transient-layers-functions
         (list (lambda (_) (error "Boom")) #'bb-transient-test--outer-layer)))
    (should (equal (mapcar #'car (bb-transient--layers bb-transient-test--fixture))
                   '("outer" "fixture")))))

(ert-deftest bb-transient-test-setup-with-layers ()
  (let* ((bb-transient-layers-functions '(bb-transient-test--outer-layer))
         (top (bb-transient--setup bb-transient-test--fixture t))
         (outer (bb-transient--sym bb-transient-test--outer '("outer")))
         (outer-zeta (bb-transient--sym bb-transient-test--outer '("zeta"))))
    (should (get top 'transient--prefix))
    ;; The outer task is defined; the outer zeta is hidden by the fixture's.
    (should (commandp outer))
    (should-not (fboundp outer-zeta))
    ;; A different set of layers is a different menu.
    (should-not (eq top (let ((bb-transient-layers-functions nil))
                          (bb-transient--setup bb-transient-test--fixture))))))

(ert-deftest bb-transient-test-setup-layer-order ()
  "The current project's group comes first, the outermost layer's last."
  (let* ((bb-transient-layers-functions '(bb-transient-test--outer-layer))
         (top (bb-transient--setup bb-transient-test--fixture t))
         (groups (aref (get top 'transient--layout) 2)))
    (should (equal (mapcar (lambda (g) (plist-get (aref g 1) :description))
                           groups)
                   '("fixture" "outer" nil)))))

(ert-deftest bb-transient-test-setup-outer-keys-first ()
  "An outer layer's keys don't depend on the project using it."
  (let* ((dir (make-temp-file "bb-transient-inner" t))
         (bb-transient-layers-functions '(bb-transient-test--outer-layer)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "bb.edn" dir)
            (insert "{:tasks {oz {:task (println \"oz\")} zeta {:task (println \"zeta\")}}}"))
          (let* ((top (bb-transient--setup dir t))
                 (groups (aref (get top 'transient--layout) 2))
                 (keys (lambda (i)
                         (mapcar (lambda (s) (plist-get (cdr s) :key))
                                 (aref (nth i groups) 2)))))
            ;; The inner `oz' would have had "o" first; the outer `outer'
            ;; has it, as it does in any project.
            (should (equal (funcall keys 0) '("z" "e")))
            (should (member "o" (funcall keys 1)))))
      (delete-directory dir t))))

(ert-deftest bb-transient-test-run-outer-task-here ()
  (let* ((bb-transient-use-comint nil)
         (default-directory bb-transient-test--fixture)
         (buf (bb-transient-run '("outer") nil bb-transient-test--outer))
         (out (bb-transient-test--wait buf)))
    (should (string-match-p "--config .*outer/bb.edn outer" out))
    (should (string-match-p
             (concat "outer in " (regexp-quote (directory-file-name
                                                (file-truename bb-transient-test--fixture))))
             out))
    (kill-buffer buf)))

;;; bb-transient-test.el ends here
