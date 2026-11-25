(ns aa.transient
  "A layer's interceptors for the ERT suite.")

(defn aa
  "Write a copy as aa, as forge does."
  [{:keys [mode path args] :as req}]
  (cond-> req
    (= mode :copy) (assoc :line (into ["aa"] (concat path args)))))

(def tricks
  "Steered by the fixture's echo --a=..., which the tests set."
  {:enter (fn [{:keys [args] :as req}]
            (let [has (set args)]
              (when (has "--a=throw")
                (throw (ex-info "Not today" {})))
              (cond-> req
                (has "--a=to-copy")  (assoc :mode :copy)
                (has "--a=to-run")   (assoc :mode :run)
                (has "--a=terminal") (assoc :terminal true)
                (has "--a=quiet")    (assoc :silent true))))})
