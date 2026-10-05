(ns demo)

(defn greet
  {:org.babashka/cli
   {:spec {:name {:desc "Your name" :require true}
           :lang {:desc "Language" :default "en" :alias :l}}}}
  [{:keys [name lang] :or {lang "en"}}]
  (println (case lang
             "zh" (str "你好, " name "！")
             (str "Hi, " name "!"))))
