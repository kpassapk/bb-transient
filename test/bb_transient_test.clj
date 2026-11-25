(ns bb-transient-test
  "Tests for bb-transient.clj's intercept.  Run with `bb test'."
  (:require [babashka.fs :as fs]
            [babashka.process :as process]
            [cheshire.core :as json]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]))

(load-file "bb-transient.clj")

(def intercept (resolve 'bb-transient.introspect/intercept))

(defn- dir [& parts]
  (str (fs/canonicalize (apply fs/path "test" parts)) "/"))

(def outer (dir "chain" "outer"))
(def inner (dir "chain" "inner"))
(def fixture (dir "fixture"))

(defn- request [& {:as m}]
  (merge {:mode :run :path ["sandbox" "up"] :args ["--id" "X"]
          :root outer :dir fixture
          :layers [{:name "outer" :root outer} {:name "inner" :root inner}]}
         m))

(deftest no-interceptors
  (testing "today's line: --config when :dir is not :root"
    (is (= ["bb" "--config" (str outer "bb.edn") "sandbox" "up" "--id" "X"]
           (:line (intercept (request :layers [{:name "fixture" :root fixture}]))))))
  (testing "plain bb when it is"
    (is (= ["bb" "test"]
           (:line (intercept {:path ["test"] :root fixture :dir fixture})))))
  (testing ":program"
    (is (= "/opt/bb" (first (:line (intercept (request :layers [] :program "/opt/bb"))))))))

(deftest order
  (is (= ["outer enter" "inner enter" "inner leave" "outer bare" "outer leave"]
         (:trace (intercept (request))))))

(deftest enter-moves-dir
  (let [out (intercept (request :move-dir true))]
    (is (= outer (:dir out)))
    (is (= ["bb" "sandbox" "up" "--id" "X"] (:line out)))))

(deftest bare-fn-is-a-leave
  (testing "it sees the built line's request and rewrites :line"
    (is (= ["aa" "sandbox" "up" "--id" "X"]
           (:line (intercept (request :mode :copy :aa true))))))
  (testing "it is not called on enter, and leaves before trace, listed before it"
    (is (= ["outer enter" "inner enter" "inner leave" "outer bare" "outer leave"]
           (:trace (intercept (request)))))))

(deftest copy-stays-copy
  (is (= :copy (:mode (intercept (request :mode "copy")))))
  (is (= :run (:mode (intercept (request))))))

(deftest throwing
  (testing "names the interceptor and the phase"
    (let [e (try (intercept (request :throw "outer leave")) nil
                 (catch Exception e e))]
      (is e)
      (is (str/includes? (ex-message e) "chain.outer/trace leave"))
      (is (str/includes? (ex-message e) "Boom"))))
  (testing "a result that is not a map"
    (let [e (try (intercept (request :bad true)) nil
                 (catch Exception e e))]
      (is (str/includes? (ex-message e) "chain.inner/trace leave returned")))))

(defn- cli [config req]
  (apply process/shell {:in (json/generate-string req) :out :string :err :string
                        :continue true}
         (concat ["bb"] (when config ["--config" config]) ["-f" "bb-transient.clj" "intercept"])))

(deftest command-line
  (testing "JSON in and out, the outer layer in this process"
    (let [{:keys [exit out]} (cli (str outer "bb.edn") (request :mode "copy" :aa true))
          res (json/parse-string out true)]
      (is (zero? exit))
      (is (= "copy" (:mode res)))
      (is (= ["aa" "sandbox" "up" "--id" "X"] (:line res)))
      (is (= ["outer enter" "inner enter" "inner leave" "outer bare" "outer leave"]
             (:trace res)))))
  (testing "a throw exits 1 with the message on stderr"
    (let [{:keys [exit err]} (cli nil (request :throw "outer enter"))]
      (is (= 1 exit))
      (is (str/includes? err "chain.outer/trace enter: Boom")))))

(deftest introspection-reports-interceptors
  (let [{:keys [out]} (process/shell {:out :string} "bb" "--config" (str outer "bb.edn")
                                     "-f" "bb-transient.clj" (str outer "bb.edn"))]
    (is (= ["chain.outer/trace" "chain.outer/aa"]
           (:interceptors (json/parse-string out true))))))
