(ns cmds)

(defn hello
  "Say hello
  to someone"
  {:bb-transient/defaults {:loud '(el/derived-mode-p 'org-mode)}
   :org.babashka/cli {:spec {:name {:desc "Who to greet" :alias :n :require true}
                             :loud {:desc "Shout" :coerce :boolean}
                             :times {:desc "Repeat count" :default 1}}}}
  [{:keys [name loud times]}]
  (dotimes [_ times]
    (println (cond-> (str "hello " name) loud .toUpperCase))))

(defn deep
  "No options"
  {:bb-transient/defaults {:a '(el/buffer-name)}}
  [_]
  (println "deep"))

(defn echo
  "Print the parsed options"
  {:org.babashka/cli {:spec [[:a {:desc "First"}] [:b {:desc "Second"}]]}}
  [opts]
  (prn opts))

(def table
  "A cmd table whose :exec-fns are vars, not symbols"
  {"echo" {:exec-fn #'cmds/echo}})

(defn top
  "Pretends to be a TUI"
  {:bb-transient/terminal true}
  [_]
  (println "top"))
