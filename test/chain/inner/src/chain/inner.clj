(ns chain.inner
  "Interceptors for the intercept tests; the request's keys steer them.")

(def trace
  {:enter (fn [req]
            (cond-> (update req :trace (fnil conj []) "inner enter")
              (:move-dir req) (assoc :dir (:root req))))
   :leave (fn [req]
            (if (:bad req)
              "not a map"
              (update req :trace (fnil conj []) "inner leave")))})
