(ns spec)

(def command
  {:doc "Commands from a var"
   :cmd {"hello" {:exec-fn 'cmds/hello}
         "inner" {:cmd {"deep" {:exec-fn 'cmds/deep}}}}})
