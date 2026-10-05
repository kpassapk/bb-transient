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

(ns bb-transient.introspect
  (:require [babashka.classpath :as cp]
            [babashka.fs :as fs]
            [cheshire.core :as json]
            [clojure.string :as str]
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

(defn- leaf [nm doc {:keys [exec-fn] :as task}]
  (let [[v err] (try [(or (requiring-resolve exec-fn)
                          (throw (ex-info (str "Unable to resolve " exec-fn) {})))
                      nil]
                     (catch Exception e [nil (ex-message e)]))
        m (meta v)
        spec (concat (spec-entries (get-in m [:org.babashka/cli :spec]))
                     (spec-entries (get-in task [:org.babashka/cli :spec])))]
    (cond-> {:name nm
             :doc (or doc (summary (:doc m)))
             :options (mapv option spec)}
      err (assoc :error err))))

(defn- node [root nm v]
  (let [nm (str nm)]
    (if-not (map? v)
      {:name nm :doc nil :options []}
      (do (doseq [p (:extra-paths v)]
            (cp/add-classpath (str (fs/path root p))))
          (cond
            (:cmd v)     {:name nm :doc (:doc v)
                          :children (mapv (fn [[k c]] (node root k c)) (:cmd v))}
            (:exec-fn v) (leaf nm (:doc v) v)
            :else        {:name nm :doc (:doc v) :options []})))))

(defn- public-task? [[k v]]
  (and (symbol? k)
       (not (str/starts-with? (name k) "-"))
       (not (and (map? v) (:private v)))))

(let [config (first *command-line-args*)
      root (str (fs/parent (fs/absolutize config)))
      tasks (:tasks (read-config config))]
  (println (json/generate-string
            {:tasks (mapv (fn [[k v]] (node root k v))
                          (filter public-task? tasks))})))
