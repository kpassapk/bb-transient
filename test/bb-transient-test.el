;;; bb-transient-test.el --- Tests for bb-transient -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'bb-transient)

(defconst bb-transient-test--fixture
  (file-name-as-directory
   (expand-file-name "fixture"
                     (file-name-directory (or load-file-name buffer-file-name)))))

(defun bb-transient-test--find (name nodes)
  (seq-find (lambda (n) (equal (alist-get 'name n) name)) nodes))

;;;; Introspection (needs bb on PATH)

(ert-deftest bb-transient-test-tree-order-and-privacy ()
  (let ((tree (bb-transient--tree bb-transient-test--fixture t)))
    (should (equal (mapcar (lambda (n) (alist-get 'name n)) tree)
                   '("zeta" "greet" "echo" "broken" "table")))))

(ert-deftest bb-transient-test-tree-specs ()
  (let* ((tree (bb-transient--tree bb-transient-test--fixture t))
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
                 "broken" (bb-transient--tree bb-transient-test--fixture t))))
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
                 "table" (bb-transient--tree bb-transient-test--fixture t)))
         (echo (bb-transient-test--find "echo" (alist-get 'children table))))
    (should-not (alist-get 'error table))
    (should (equal (alist-get 'doc echo) "Print the parsed options"))
    (should (equal (mapcar (lambda (o) (alist-get 'name o))
                           (alist-get 'options echo))
                   '("a" "b")))))

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
                 '("--title=A b" "--x" "1" "two words"))))

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

(ert-deftest bb-transient-test-run-end-to-end ()
  (let* ((bb-transient-use-comint nil)
         (buf (bb-transient--run bb-transient-test--fixture
                                 '("greet" "hello") '("--name=ert" "--loud"))))
    (with-current-buffer buf
      (while (get-buffer-process buf) (accept-process-output nil 0.1))
      (should (string-match-p "HELLO ERT" (buffer-string))))
    (kill-buffer buf)))

;;; bb-transient-test.el ends here
