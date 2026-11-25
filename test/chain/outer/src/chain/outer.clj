(ns chain.outer
  "Interceptors for the intercept tests; the request's keys steer them.")

(defn- note [req s]
  (when (= (:throw req) s)
    (throw (ex-info "Boom" {})))
  (update req :trace (fnil conj []) s))

(def trace
  {:name ::trace
   :enter #(note % "outer enter")
   :leave #(note % "outer leave")})

(defn aa
  "A bare function, so a :leave: a copy is written as aa, when asked."
  [{:keys [mode path args] :as req}]
  (cond-> (note req "outer bare")
    (and (:aa req) (= mode :copy)) (assoc :line (into ["aa"] (concat path args)))))
