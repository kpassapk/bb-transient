;; Introspect a project's bb.edn for bb-transient.
;;
;; Run as `bb --config <root>/bb.edn -f bb-transient.clj <root>/bb.edn`,
;; so the project's :paths and :deps are on the classpath and every
;; :exec-fn can be resolved.  Prints the command tree as JSON:
;;
;;   {"tasks": [{"name": "work", "doc": "...",
;;               "children": [{"name": "new", "doc": "...",
;;                             "options": [{"name": "title", ...}]}]}]}
;;
;; A node has either "children" (a :cmd table) or "options" (a leaf).
;; A leaf marked `:bb-transient/terminal true', in its task map or on
;; its :exec-fn's metadata, also carries "terminal": true.  The same
;; goes for `:bb-transient/singleton true' and "singleton": true, and
;; for `:bb-transient/silent true' and "silent": true.
;;
;; `:bb-transient/defaults' maps option names to cljbang forms that
;; Emacs evaluates to fill those options in.  The top-level one in
;; bb.edn covers every leaf with that option; one in a task map or on
;; an :exec-fn's metadata (quoted there, since metadata is evaluated)
;; replaces it for that leaf.  A leaf gets only the forms for options it
;; has, each as a string: "defaults": {"id": "(el/org-entry-get ...)"}.
;;
;; `:bb-transient/before' and `:bb-transient/after' name a hook Emacs
;; runs around one command: a qualified symbol or an (fn ...) form, in
;; the task map or (quoted) on the :exec-fn's metadata, the task map
;; winning.  A node that has one carries it as a string:
;; "before": "forge.hooks/save-book".  The top-level
;; `:bb-transient/cljbang-paths' is sent once, next to "tasks", and so
;; is `:bb-transient/interceptors', as "interceptors": ["ns/var", ...].
;;
;; Run as `bb [--config <layer>/bb.edn] -f bb-transient.clj intercept',
;; it reads a request as JSON on stdin, threads it through the
;; interceptors of the layers in its "layers", and prints the final
;; request as JSON:
;;
;;   1. every :enter, outermost layer first;
;;   2. :line, the words of the bb command line, from :dir, :root,
;;      :path and :args;
;;   3. every :leave, innermost layer first.
;;
;; That is Pedestal's order with the layers' lists as one queue: the
;; :leave fns run in exactly the reverse order of the :enter fns, a
;; layer's own list too.
;;
;; A layer's interceptors run on its own classpath: in this process
;; when it was started with that layer's bb.edn as --config, else in a
;; `bb --config <layer>/bb.edn' of their own.  An interceptor that
;; throws, or returns something other than a map, makes it exit 1 with
;; a message naming it on stderr.

(ns bb-transient.introspect
  (:require [babashka.classpath :as cp]
            [babashka.fs :as fs]
            [cheshire.core :as json]
            [clojure.edn :as edn]
            [clojure.string :as str]
            [babashka.process :as process]
            [rewrite-clj.node :as n]
            [rewrite-clj.parser :as p]))

(defn- ->data
  "Like `n/sexpr`, but maps keep their source order, so tasks and
  commands come out in the order bb.edn lists them."
  [node]
  (let [kids #(remove (fn [c] (or (n/whitespace-or-comment? c)
                                  (= :uneval (n/tag c))))
                      (n/children node))]
    (case (n/tag node)
      :map    (apply array-map (map ->data (kids)))
      :vector (mapv ->data (kids))
      :list   (apply list (map ->data (kids)))
      (n/sexpr node))))

(defn- read-config [file]
  (->> (p/parse-string-all (slurp file))
       n/children
       (some #(when (= :map (n/tag %)) %))
       ->data))

(defn- jsonable [x]
  (if (or (string? x) (number? x) (boolean? x) (nil? x)) x (pr-str x)))

(defn- summary
  "A docstring's first paragraph, on one line."
  [s]
  (some-> s str str/trim (str/split #"\n\s*\n") first (str/replace #"\s+" " ")))

(defn- spec-entries
  "babashka.cli takes a spec as a map or as a vector of [k opts] pairs."
  [spec]
  (if (map? spec) (seq spec) spec))

(defn- option [[k {:keys [desc alias require default coerce]}]]
  {:name (name k)
   :desc desc
   :alias (some-> alias name)
   :require (boolean require)
   :default (jsonable default)
   :boolean (= :boolean coerce)})

(defn- resolve-var
  "A var for SYM-OR-VAR (bb.edn may hold either), or throw."
  [x]
  (cond (var? x) x
        (symbol? x) (or (requiring-resolve x)
                        (throw (ex-info (str "Unable to resolve " x) {})))
        :else (throw (ex-info (str "Not a symbol or var: " (pr-str x)) {}))))

(defn- terminal? [& maps]
  (boolean (some :bb-transient/terminal maps)))

(defn- singleton? [& maps]
  (boolean (some :bb-transient/singleton maps)))

(defn- silent? [& maps]
  (boolean (some :bb-transient/silent maps)))

(defn- hooks
  "The hooks in MAPS (earlier ones win), as strings."
  [& maps]
  (into {}
        (keep (fn [[k json-key]]
                (when-let [form (some k maps)] [json-key (pr-str form)])))
        {:bb-transient/before :before :bb-transient/after :after}))

(defn- leaf-defaults
  "The forms in DEFAULTS and MAPS (later ones win) for SPEC's options."
  [spec defaults & maps]
  (let [names (set (map first spec))]
    (not-empty
     (into {}
           (keep (fn [[k form]]
                   (when (names (keyword k)) [(name k) (pr-str form)])))
           (apply merge defaults (map :bb-transient/defaults maps))))))

(defn- leaf [defaults nm doc {:keys [exec-fn] :as task}]
  (let [[v err] (try [(resolve-var exec-fn) nil]
                     (catch Exception e [nil (ex-message e)]))
        m (meta v)
        spec (concat (spec-entries (get-in m [:org.babashka/cli :spec]))
                     (spec-entries (get-in task [:org.babashka/cli :spec])))
        d (leaf-defaults spec defaults m task)]
    (cond-> (merge {:name nm
                    :doc (or doc (summary (:doc m)))
                    :options (mapv option spec)}
                   (hooks task m))
      (terminal? task m) (assoc :terminal true)
      (singleton? task m) (assoc :singleton true)
      (silent? task m) (assoc :silent true)
      d (assoc :defaults d)
      err (assoc :error err))))

(defn- cmd-table
  "A :cmd value is a map, or a symbol naming a var that holds one."
  [cmd]
  (if (map? cmd) cmd @(resolve-var cmd)))

(defn- node [root defaults nm v]
  (let [nm (if (keyword? nm) (name nm) (str nm))]
    (if-not (map? v)
      {:name nm :doc nil :options []}
      (do (doseq [p (:extra-paths v)]
            (cp/add-classpath (str (fs/path root p))))
          (cond
            (:cmd v)     (let [[cmd err] (try [(cmd-table (:cmd v)) nil]
                                              (catch Exception e [nil (ex-message e)]))]
                           (cond-> {:name nm :doc (:doc v)
                                    :children (mapv (fn [[k c]] (node root defaults k c)) cmd)}
                             err (assoc :error err)))
            (:exec-fn v) (leaf defaults nm (:doc v) v)
            :else        (cond-> (merge {:name nm :doc (:doc v) :options []}
                                           (hooks v))
                           (terminal? v) (assoc :terminal true)
                           (singleton? v) (assoc :singleton true)
                           (silent? v) (assoc :silent true)))))))

(defn- public-task? [[k v]]
  (and (symbol? k)
       (not (str/starts-with? (name k) "-"))
       (not (and (map? v) (:private v)))))

(defn- introspect [config]
  (let [root (str (fs/parent (fs/absolutize config)))
        {:keys [tasks]
         defaults :bb-transient/defaults
         paths :bb-transient/cljbang-paths
         interceptors :bb-transient/interceptors} (read-config config)]
    (println (json/generate-string
              (cond-> {:tasks (mapv (fn [[k v]] (node root defaults k v))
                                    (filter public-task? tasks))}
                paths (assoc :cljbang-paths paths)
                (seq interceptors) (assoc :interceptors (mapv str interceptors)))))))

;;;; Interceptors

(def ^:private script *file*)

(defn- config-file [root]
  (str (fs/path root "bb.edn")))

(defn- same-file? [a b]
  (let [canon #(str (if (fs/exists? %) (fs/canonicalize %) (fs/normalize (fs/absolutize %))))]
    (= (canon a) (canon b))))

(defn layer-interceptors
  "The symbols in the :bb-transient/interceptors of the bb.edn in ROOT."
  [root]
  (let [f (config-file root)]
    (when (fs/exists? f)
      (seq (:bb-transient/interceptors (read-config f))))))

(defn line
  "The words of the command line for REQ: bb, its bb.edn as --config when
  :dir is not :root, then :path and :args."
  [{:keys [program dir root path args]}]
  (vec (concat [(or program "bb")]
               (when (and root dir (not (same-file? dir root)))
                 ["--config" (config-file root)])
               path args)))

(defn- interceptor [sym]
  (let [v @(resolve-var sym)]
    (cond (map? v) v
          (ifn? v) {:leave v}
          :else (throw (ex-info (str sym " is not an interceptor: " (pr-str v)) {})))))

(defn run-phase
  "Thread REQ through the PHASE (:enter or :leave) fns of the
  interceptors SYMS, in order, in this process."
  [phase syms req]
  (reduce (fn [req sym]
            (let [f (try (get (interceptor sym) phase)
                         (catch Exception e
                           (throw (ex-info (str sym ": " (ex-message e)) {:interceptor sym} e))))]
              (if-not f
                req
                (let [out (try (f req)
                               (catch Exception e
                                 (throw (ex-info (str sym " " (name phase) ": " (ex-message e))
                                                 {:interceptor sym} e))))]
                  (if (map? out)
                    out
                    (throw (ex-info (str sym " " (name phase) " returned "
                                         (pr-str out) ", not a map")
                                    {:interceptor sym})))))))
          req syms))

(defn- run-layer
  "REQ through the PHASE of the layer at ROOT, whose interceptors are SYMS.
  A :leave goes through them last to first."
  [phase {:keys [root syms]} req]
  (let [syms (vec (if (= :leave phase) (reverse syms) syms))]
    (if (same-file? (config-file root) (or (System/getProperty "babashka.config") ""))
      (run-phase phase syms req)
      (let [{:keys [exit out err]}
            (process/shell {:in (binding [*print-namespace-maps* false] (pr-str req))
                            :out :string :err :string :continue true :dir (str root)}
                           "bb" "--config" (config-file root) "-f" script
                           "phase" (name phase) (pr-str syms))]
        (if (zero? exit)
          ;; Namespaces may print as they load; the request is the last line.
          (edn/read-string (last (str/split-lines out)))
          (throw (ex-info (or (not-empty (str/trim err))
                              (str "bb --config " (config-file root) " exited " exit))
                          {})))))))

(defn- normalize [req]
  (-> req
      (update :mode #(keyword (or (some-> % name) "run")))
      (update :path #(vec (or % [])))
      (update :args #(vec (or % [])))
      (update :layers #(vec (or % [])))
      (update :terminal boolean)
      (update :silent boolean)))

(defn intercept
  "REQ, a request, threaded through the interceptors of its :layers:
  every :enter outermost first, then :line, then every :leave in the
  reverse order.  A :copy stays a :copy."
  [req]
  (let [req (normalize req)
        layers (keep (fn [{:keys [root]}]
                       (when-let [syms (layer-interceptors root)]
                         {:root root :syms syms}))
                     (:layers req))
        out (as-> req r
              (reduce #(run-layer :enter %2 %1) r layers)
              (assoc r :line (line r))
              (reduce #(run-layer :leave %2 %1) r (reverse layers)))
        l (:line out)]
    (when-not (and (sequential? l) (seq l) (every? string? l))
      (throw (ex-info (str ":line is not a list of words: " (pr-str l)) {})))
    (when (and (:dir req) (not (string? (:dir out))))
      (throw (ex-info (str ":dir is not a directory: " (pr-str (:dir out))) {})))
    (assoc out
           :line (vec l)
           :mode (if (or (= :copy (:mode req)) (= :copy (keyword (name (:mode out)))))
                   :copy
                   :run))))

(defn- jsonable-tree [x]
  (cond (map? x) (into {} (map (fn [[k v]] [k (jsonable-tree v)])) x)
        (sequential? x) (mapv jsonable-tree x)
        (set? x) (mapv jsonable-tree x)
        (or (string? x) (number? x) (boolean? x) (nil? x) (keyword? x)) x
        :else (pr-str x)))

(defn- fail [e]
  (binding [*out* *err*]
    (println (ex-message e)))
  (System/exit 1))

(when (= script (System/getProperty "babashka.file"))
  (let [[cmd & more] *command-line-args*]
    (case cmd
      "intercept" (try (-> (json/parse-string (slurp *in*) true)
                           intercept
                           jsonable-tree
                           json/generate-string
                           println)
                       (catch Exception e (fail e)))
      "phase" (try (let [[phase syms] more]
                     (prn (run-phase (keyword phase) (edn/read-string syms)
                                     (edn/read-string (slurp *in*)))))
                   (catch Exception e (fail e)))
      (introspect cmd))))
