# bb-transient

Transient menus for the task CLI in a project's `bb.edn`.

`M-x bb-transient` in any buffer under a project with a `bb.edn` opens a
menu of its tasks.  Tasks with a `:cmd` table open a submenu; commands
with a babashka.cli spec open an options menu; anything else runs as
soon as its key is pressed.  Commands run from the project root in a
`compilation-mode` buffer named `*bb <command>*`.

## How the menus are built

bb reads the tree, not `--help`.  `bb-transient.clj` runs under the
project's own `bb.edn` (so its `:paths` and `:deps` are on the
classpath), walks `:tasks` and nested `:cmd` tables in file order,
resolves each `:exec-fn`, and reads the `:spec` from its
`:org.babashka/cli` metadata:

| spec                 | menu                                     |
|----------------------|------------------------------------------|
| `:coerce :boolean`   | switch `--flag`                          |
| anything else        | option `--name=`                         |
| `:alias :t`          | key `-t`, when free                      |
| `:require true`      | marked "(required)", checked before run  |
| `:default x`         | shown as "(default x)"                   |

Every options menu also has `-=` for extra arguments, split like a
shell command line, for flags the spec doesn't declare.

Tasks named `-foo` or marked `:private true` are left out.  The tree is
cached per project and re-read when `bb.edn` changes; `g` in the top
menu re-reads it after you edit a spec in a `.clj` file.

## Setup

```elisp
(use-package bb-transient
  :vc (:url "https://github.com/kpassapk/bb-transient")
  :commands bb-transient)
```

Optionally add it to `project-switch-commands`:

```elisp
(add-to-list 'project-switch-commands '(bb-transient "bb tasks" ?b))
```

`bb-transient-use-comint` (default `t`) runs commands in comint mode so
they can read input; `bb-transient-program` is the bb executable.

## Development

```
bb ci      # byte-compile (warnings are errors), then the ERT suite
```

The tests need `bb` on `PATH`; they introspect and run the project in
`test/fixture`.
