(ns fixture.hooks)

(defn record
  "Keep the after hook's map, and the buffer it ran in, for the tests."
  [m]
  (el/set 'bb-transient-test--after (assoc m :in (el/buffer-name))))
