# bb-transient

Emacs [transient][transient] menus for [babashka](https://github.com/babashka/babashka) tasks.

![bb-transient](./resources/bb-transient.gif)

Babashka tasks [recently][bb-changelog] gained [subcommands and
switches][bb-tasks], so a `bb.edn` can now be a full project CLI.
bb-transient reads that CLI's spec and turns it into a menu: browse
subcommands, set options, and see the output.

This library is written with AI assistance. If you find a bug, please
open an issue.

[bb-changelog]: https://github.com/babashka/babashka/blob/master/CHANGELOG.md#113219-2026-07-27
[bb-tasks]: https://blog.michielborkent.nl/babashka-tasks-cli.html
[transient]: https://github.com/magit/transient

## Installation

```elisp
(use-package bb-transient
  :vc (:url "https://github.com/kpassapk/bb-transient")
  :commands bb-transient)

;; Optional: add it to `project-switch-project'
(add-to-list 'project-switch-commands '(bb-transient "bb tasks" ?b))
```

Some features (defaults from point, hooks) also need
[cljbang][cljbang]. [ghostel][ghostel] is needed only for terminal
commands.

## Usage

`M-x bb-transient` opens a menu of the nearest `bb.edn`'s tasks:

- a task with a `:cmd` table opens a submenu,
- a command with a `babashka.cli` spec opens an options menu,
- anything else runs as soon as its key is pressed.

Commands run from the project root in a `*bb <command>*`
compilation buffer.

The options menu is built from the `:spec` in each `:exec-fn`'s
`:org.babashka/cli` metadata:

| Spec               | Menu                                    |
|--------------------|-----------------------------------------|
| `:coerce :boolean` | switch `--flag`                         |
| anything else      | option `--name=`                        |
| `:alias :t`        | key `-t`, if free                       |
| `:require true`    | marked "(required)", checked before run |
| `:default x`       | shown as "(default x)"                  |

Tasks named `-foo` or marked `:private true` are hidden.

### Keys

| Key   | Where        | Does                                                   |
|-------|--------------|--------------------------------------------------------|
| `-=`  | options menu | extra arguments, split like a shell command line       |
| `t`   | options menu | toggle running in a terminal, for this run             |
| `s`   | options menu | toggle silent, for this run                            |
| `_`   | options menu | copy the command line instead of running it            |
| `_`   | top menu     | copy instead of run for the next command picked        |
| `C-u` | any menu     | run a bare command (no options menu) in a terminal     |
| `g`   | top menu     | re-read the task tree (after editing a spec in `.clj`) |

The tree is cached per project and re-read automatically when `bb.edn`
changes.

## Task options

These keys go in a task map or on the `:exec-fn`'s metadata (the task
map wins). Hooks and defaults on metadata must be quoted.

```clojure
{:bb-transient/cljbang-paths ["emacs"]          ; where hook namespaces live
 :bb-transient/defaults {:id (el/org-entry-get nil "ID" true)}
 :tasks
 {watch    {:exec-fn tasks/watch    :bb-transient/terminal true}
  serve    {:exec-fn tasks/serve    :bb-transient/singleton true}
  snapshot {:exec-fn work/snapshot  :bb-transient/silent true}
  init     {:exec-fn tasks/init     :bb-transient/after forge.hooks/open-project}}}
```

| Key                       | Effect                                       |
|---------------------------|----------------------------------------------|
| `:bb-transient/terminal`  | run in a real terminal (for TUIs)            |
| `:bb-transient/singleton` | only one running copy                        |
| `:bb-transient/silent`    | show output only on failure or a prompt      |
| `:bb-transient/before`    | cljbang hook called before the command       |
| `:bb-transient/after`     | cljbang hook called after the command exits  |
| `:bb-transient/defaults`  | fill options from where point is             |

And at the top level of `bb.edn`:

| Key                            | Effect                                         |
|--------------------------------|------------------------------------------------|
| `:bb-transient/cljbang-paths`  | where hook namespaces live                     |
| `:bb-transient/defaults`       | defaults for every command with that option    |
| `:bb-transient/interceptors`   | how this layer's commands are run and copied   |

### Terminal

Full-screen UIs run in an interactive [ghostel][ghostel]
`ghostel-compile` buffer. Once the command exits it behaves like any
compilation buffer (`g` reruns, `next-error` works).

### Singleton

For dev servers and watchers. If the command is still running, running
it again just shows its buffer; options are ignored and no hook is
called. A singleton is identified by its task path, so `serve --port=1`
and `serve --port=2` are the same one.

### Silent

The buffer stays hidden:

- exit 0 shows a message, `bb snapshot: done`;
- any other exit pops up the buffer and points `next-error` at it;
- a line with no trailing newline and no output for 0.3 s is taken
  as a prompt and pops up the buffer.

The prompt check is a guess. A prompt ending in a newline, or one that
isn't flushed (`print` without `flush`), goes unseen and the command
waits in the hidden buffer. A progress line ending in `\r` pops it up
for nothing. Terminal commands are never silent.

### Defaults from point

`:bb-transient/defaults` maps option names to [cljbang][cljbang] forms,
evaluated in the buffer the menu was opened from. A top-level map
applies to every command that has that option.

```clojure
:bb-transient/defaults
{:id   (el/org-entry-get nil "ID" true)
 :book (some->> (el/buffer-file-name)
                (re-find (re-pattern "--\\([^/_.]+\\)"))
                second)}
```

- `nil` or an error leaves the option blank; a non-nil value turns a
  boolean on.
- A filled value replaces the one transient remembered, and satisfies
  "(required)".
- `bb` reads `bb.edn` too, so `#"..."` and `#(...)` aren't allowed. Use
  `re-pattern` (Emacs regex syntax) and `fn`. Longer forms read better
  in a cljbang file.

### Hooks

A hook is a qualified symbol, required from
`:bb-transient/cljbang-paths`, or an inline `(fn ...)`.

```clojure
;; emacs/forge/hooks.clj
(ns forge.hooks
  (:require [clojure.string :as str]))

(defn save-book [_]
  (el/save-some-buffers true)
  nil)

(defn open-book [{:keys [exit out]}]
  (when (zero? exit)
    (el/find-file (el/expand-file-name "workbook.org"
                                       (-> out str/trim str/split-lines last)))))
```

- **before** gets `{:args [...] :dir "..."}` in the original buffer. It
  returns new args, or `nil` to keep them. If it throws, the command
  doesn't run.
- **after** gets `{:exit 0 :out "..." :buffer <buf> :args [...]}` when
  the process exits, in the original buffer if still live. `:out` is the
  command's output (in a terminal, the whole buffer).
- Only commands run from a menu get hooks, not `bb-transient-run`.

### Interceptors

A layer can change how a command is run or copied, for every menu it
is a layer of. It lists interceptors at the top level of its `bb.edn`:

```clojure
;; forge's bb.edn
{:paths ["src"]
 :bb-transient/interceptors [atomforge.transient/aa]
 ...}
```

Each is a qualified symbol naming a var on that layer's classpath
(`:paths`, `:deps`), holding an interceptor:

```clojure
;; src/atomforge/transient.clj
(ns atomforge.transient)

(def aa
  "Copy a command as aa. Runs still use bb --config."
  {:name  ::aa
   :leave (fn [{:keys [mode path args] :as req}]
            (cond-> req
              (= mode :copy) (assoc :line (into ["aa"] (concat path args)))))})
```

`:enter` and `:leave` are each a function of the request that
returns the request. Either may be left out, and a bare function is a
`:leave`. They must be **pure**: no output, no files written, no
processes. They may read files. Effects belong in hooks.

Picking a command, to run or to copy, makes the request:

| Key         | Example                                      | What it is                                |
|-------------|----------------------------------------------|-------------------------------------------|
| `:mode`     | `:run` or `:copy`                            | what the menu is doing                    |
| `:path`     | `["sandbox" "up"]`                           | the command                               |
| `:args`     | `["--id=X"]`                                 | its options and extra arguments           |
| `:root`     | `".../forge/"`                               | the layer the command is from             |
| `:dir`      | `".../my-project/"`                          | where it runs                             |
| `:layers`   | `[{:name "atomstream/forge" :root "..."} …]` | the menu's layers, outermost first        |
| `:origin`   | `{:file ".../task.org" :directory "..."}`    | the buffer the menu was opened from       |
| `:task`     | `{:name "up" :options [...] :silent true}`   | the command's node, as introspection read it |
| `:terminal` | `false`                                      | run in a terminal                         |
| `:silent`   | `true`                                       | run silently                              |
| `:program`  | `"bb"`                                       | `bb-transient-program`                    |
| `:line`     | `["bb" "--config" ".../bb.edn" "sandbox" …]` | the command line, as words                |

The chain is Pedestal's, with the layers' lists as one queue:

1. every `:enter`, outermost layer first: change what runs (`:path`,
   `:args`, `:dir`);
2. `:line` is built from `:dir`, `:root`, `:path` and `:args`: `bb
   --config <root>/bb.edn …` when `:dir` is not `:root`, else `bb …`;
3. every `:leave`, in the reverse order, so the outermost layer has the
   last word: change how it is written (`:line`).

Emacs then reads back `:mode`, `:line`, `:dir`, `:terminal` and
`:silent`, and copies the line or runs it in `:dir`. `:line` is words;
Emacs quotes them for the shell. `:mode` can go from `:run` to `:copy`
(a command to paste into a block, not run from Emacs), never back.

On a run, the before hook runs first and its args go into the request.
If an interceptor throws, a copy gets the line without the layers and
a message says why; a run doesn't run, and the message names the
interceptor.

The chain runs in bb: `bb-transient.clj intercept` reads the request
as JSON on stdin and prints the final one, running each layer's
interceptors on that layer's classpath. A menu whose layers list no
interceptors starts no process for it. To test an interceptor, call
it on a map with `bb test` in its own layer.

### Trust

Defaults and hooks run code inside Emacs. `bb-transient-eval-hooks` is
`ask` (once per project per session) by default; set it to `t` or `nil`
to always or never allow. Untrusted projects, or a missing cljbang, run
commands without them.

## Customization

| Variable                          | Default                     | Purpose                              |
|-----------------------------------|-----------------------------|--------------------------------------|
| `bb-transient-program`            | `"bb"`                      | bb executable                        |
| `bb-transient-use-comint`         | `t`                         | let commands read input              |
| `bb-transient-project-function`   | nearest `bb.edn`            | which project's menu opens           |
| `bb-transient-directory-function` | project root                | where commands run                   |
| `bb-transient-eval-hooks`         | `ask`                       | trust for defaults and hooks         |
| `bb-transient-layers-command`     | `nil`                       | other projects' tasks in the menu    |

### Layers

Show tasks from other projects in the same menu, a group per project.
`bb-transient-layers-command` is a program and its arguments, run in
the current project root, that prints the layers as JSON, outermost
first:

```elisp
(setq bb-transient-layers-command '("atomforge" "layers" "--json"))
```

```json
[{"name": "atomstream/forge", "root": "/home/me/src/forge/"}]
```

A relative `root` is taken from the project. Its output is cached and
read again when a `bb.edn` in the chain changes, or on `g`.

Every command runs from the current project, as `bb --config
<other>/bb.edn <task>`. Inner tasks hide outer ones of the same name
(`:cmd` tables aren't merged). Outer projects get keys first, so shared
keys stay stable across projects. The layers are also the chain a
command's [interceptors](#interceptors) run in.

`bb-transient-layers-functions`, functions of the project root
returning `(LABEL . DIRECTORY)` pairs, is obsolete; it is used only
when the command is nil.

### Lisp API

- `(bb-transient-run PATH &optional ARGS PROJECT TERMINAL SILENT)` runs a task.
- `(bb-transient-command-line PATH &optional ARGS PROJECT)` returns the command string a run would use, interceptors included.
- `(bb-transient-tasks ROOT)` returns a project's task tree.

[cljbang]: https://github.com/kpassapk/cljbang.el
[ghostel]: https://github.com/dakra/ghostel

## Development

```sh
bb ci        # byte-compile (warnings are errors), then the tests
bb test:clj  # only bb-transient.clj's tests, no Emacs needed
```

Tests need `bb` on `PATH`. Set `CLJBANG` to cljbang's directory to run
the defaults tests too.
