(in-package #:org.shirakumo.dns-client)

(defconstant DNS-PORT 53)
(defconstant RECV-BUFFER-LENGTH 4096)

(defvar *cloudflare-servers*
  '("1.1.1.1" "1.0.0.1"))
(defvar *dnswatch-servers*
  '("84.200.69.80" "84.200.70.40"))
(defvar *google-servers*
  '("8.8.8.8" "8.8.4.4"))
(defvar *opendns-servers*
  '("208.67.222.123" "208.67.220.123"))
(defvar *quad9-servers*
  '("9.9.9.9" "149.112.112.112"))
(defvar *dns-servers*
  (list* "127.0.0.1"
         (append *dnswatch-servers* *quad9-servers*
                 *cloudflare-servers* *opendns-servers*
                 *google-servers*)))

(defun encode-host (name octets offset)
  (let ((start 0)
        (name (org.shirakumo.punycode:encode-domain name)))
    (flet ((finish (end)
             (setf (aref octets (+ offset start)) (- end start))
             (loop for i from (1+ start) to end
                   do (setf (aref octets (+ offset i)) (char-code (char-downcase (char name (1- i))))))
             (setf start (1+ end))))
      (loop for i from 0 below (length name)
            do (when (char= #\. (char name i))
                 (finish i))
            finally (finish (length name)))
      (setf (aref octets (+ offset start)) 0)
      (+ offset start 1))))

(defun decode-host* (string)
  (loop with i = 0
        while (< i (length string))
        do (let ((jump (char-code (char string i))))
             (setf (char string i) #\.)
             (incf i (1+ jump))))
  (org.shirakumo.punycode:decode-domain
   (if (string/= "" string)
       (subseq string 1)
       string)))

(defun decode-host (octets index start end)
  (let ((pos index)
        (state 0)
        (compress-start 0)
        (loops 0)
        (stream (make-string-output-stream)))
    (flet ((check-loop ()
             (when (<= 1000 (incf loops))
               (error "Bad host: exceeded decompression iterations"))))
      (loop (when (<= end pos)
              (error "Bad host: jumped outside the buffer"))
            (check-loop)
            (let ((octet (aref octets pos)))
              (incf pos)
              (cond ((< 0 state)
                     (write-char (code-char octet) stream)
                     (decf state))
                    (T
                     (loop while (<= #xC0 octet)
                           do (when (<= end pos)
                                (error "Bad host: jump label at end of buffer"))
                              (let ((where (ash (- octet #xC0) 8)))
                                (setf octet (aref octets pos))
                                (incf pos)
                                (when (= 0 compress-start)
                                  (setf compress-start pos))
                                (setf pos (+ start octet where))
                                (setf octet (aref octets pos))
                                (incf pos)
                                (check-loop)))
                     (when (<= #x40 octet)
                       (error "Bad host: DNS label length is disallowed 0x~2x value" octet))
                     (when (= 0 octet)
                       (return (values (decode-host* (get-output-stream-string stream))
                                       (if (= 0 compress-start) pos compress-start))))
                     (write-char (code-char octet) stream)
                     (setf state octet))))))))

(defun decode-header (octets offset)
  (with-decoding (octets offset pos)
    (values (list :id (int16)
                  :recursion-desired (int1)
                  :truncated-message (int1)
                  :authorative-answer (int1)
                  :operation (int4)
                  :reply-p (int1)
                  :response-code (int4)
                  :checking-disabled (int1)
                  :authenticated-data (int1)
                  :z-reserved (int1)
                  :recursion-available (int1)
                  :question-count (int16)
                  :answer-count (int16)
                  :authority-count (int16)
                  :additional-count (int16))
            pos)))

(defun encode-header (octets offset &key id recursion-desired truncated-message authorative-answer operation reply-p response-code checking-disabled authenticated-data z-reserved recursion-available question-count answer-count authority-count additional-count)
  (maybe-set (octets offset)
    (int16 id)
    (int1 recursion-desired)
    (int1 truncated-message)
    (int1 authorative-answer)
    (int4 operation)
    (int1 reply-p)
    (int4 response-code)
    (int1 checking-disabled)
    (int1 authenticated-data)
    (int1 z-reserved)
    (int1 recursion-available)
    (int16 question-count)
    (int16 answer-count)
    (int16 authority-count)
    (int16 additional-count)))

(defun encode-query (octets offset hostname &key type class)
  (let ((type (etypecase type
                ((or string symbol) (record-type-id type))
                ((unsigned-byte 16) type))))
    (setf offset (encode-host hostname octets offset))
    (maybe-set (octets offset)
      (int16 type)
      (int16 class))))

(defun decode-query (octets offset)
  (with-decoding (octets offset pos)
    (values (list :type (id-record-type (int16))
                  :class (int16))
            pos)))

(defun decode-data (octets offset)
  (with-decoding (octets offset pos)
    (values (list :type (id-record-type (int16))
                  :class (int16)
                  :ttl (int32)
                  :length (int16))
            pos)))

(defgeneric decode-record-payload (type octets start end))

(defmethod decode-record-payload (type octets start end)
  (subseq octets start end))

(defmethod decode-record-payload ((type (eql :A)) octets start end)
  (format NIL "~d.~d.~d.~d"
          (aref octets (+ 0 start))
          (aref octets (+ 1 start))
          (aref octets (+ 2 start))
          (aref octets (+ 3 start))))

(defmethod decode-record-payload ((type (eql :AAAA)) octets start end)
  (usocket:vector-to-ipv6-host octets))

(defmethod decode-record-payload ((type (eql :TXT)) octets start end)
  (decode-host octets start 0 end))

(defmethod decode-record-payload ((type (eql :URI)) octets start end)
  (decode-host octets start 0 end))

(defmethod decode-record-payload ((type (eql :CNAME)) octets start end)
  (decode-host octets start 0 end))

(defmethod decode-record-payload ((type (eql :PTR)) octets start end)
  (decode-host octets start 0 end))

;; TODO: decode more.

(defmethod decode-record-payload ((type (eql :MX)) octets start end)
  (with-decoding (octets start pos)
    (list :priority (int16)
          :name (decode-host octets pos 0 end))))

(defmethod decode-record-payload ((type (eql :SOA)) octets start end)
  (multiple-value-bind (mname pos) (decode-host octets start 0 end)
    (multiple-value-bind (rname pos) (decode-host octets pos 0 end)
      (with-decoding (octets pos)
        (list :mname mname
              :rname rname
              :serial (int32)
              :refresh (int32)
              :retry (int32)
              :expire (int32)
              :minimum (int32))))))

(defun decode-record (octets offset)
  (multiple-value-bind (data pos) (decode-data octets offset)
    (setf (getf data :data) (decode-record-payload (getf data :type) octets pos (+ pos (getf data :length))))
    (values data (+ pos (getf data :length)))))

(defun decode-response (server octets offset limit)
  ;; FIXME: Implement buffer limiting.
  (multiple-value-bind (header pos) (decode-header octets offset)
    (when (< 0 (getf header :response-code))
      (error 'dns-server-failure :dns-server server :response-code (getf header :response-code)))
    (let ((record-offset pos))
      (flet ((decode (fun)
               (multiple-value-bind (name pos) (decode-host octets record-offset offset limit)
                 (multiple-value-bind (query pos) (funcall fun octets pos)
                   (setf record-offset pos)
                   (setf (getf query :name) name)
                   query))))
        (list* :questions
               (loop repeat (getf header :question-count)
                     collect (decode #'decode-query))
               :answers
               (loop repeat (getf header :answer-count)
                     collect (decode #'decode-record))
               :authorities
               (loop repeat (getf header :authority-count)
                     collect (decode #'decode-record))
               :additional
               (loop repeat (getf header :additional-count)
                     collect (decode #'decode-record))
               header)))))

(defun try-server (server send send-length recv recv-length &key (attempts 1) (timeout 1))
  (handler-case
      (let ((socket (usocket:socket-connect server DNS-PORT
                                            :protocol :datagram
                                            :element-type '(unsigned-byte 8)
                                            :timeout 1)))
        (unwind-protect
             (loop repeat attempts
                   do (usocket:socket-send socket send send-length)
                      (when (usocket:wait-for-input socket :timeout timeout :ready-only T)
                        (let ((received (nth-value 1 (usocket:socket-receive socket recv recv-length))))
                          (when (and received (< 0 received))
                            (return received)))))
          (usocket:socket-close socket)))
    #+sbcl
    (sb-bsd-sockets:socket-error (e)
      (values NIL e))
    (usocket:socket-error (e)
      (values NIL e))))

(defmacro with-query-buffer ((send pos hostname type &rest header-args) &body body)
  `(let* ((,send (make-array 512 :element-type '(unsigned-byte 8) :initial-element 0))
          (,pos (encode-header ,send 0 :id 42 :recursion-desired T :question-count 1 ,@header-args))
          (,pos (encode-query ,send ,pos ,hostname :type ,type :class 1)))
     (declare (dynamic-extent ,send))
     ,@body))

(defun query (hostname &key (type T) (dns-servers *dns-servers*) (attempts 1) (timeout 1))
  (with-simple-restart (abort "Abort the DNS query.")
    (let ((recv (make-array RECV-BUFFER-LENGTH :element-type '(unsigned-byte 8) :initial-element 0)))
      (declare (dynamic-extent recv))
      (with-query-buffer (send send-length hostname type)
        (loop for server in dns-servers
              for recv-length = (try-server server send send-length recv RECV-BUFFER-LENGTH :attempts attempts :timeout timeout)
              do (when recv-length
                   (with-simple-restart (continue "Skip this DNS server.")
                     (return (decode-response server recv 0 recv-length))))
              finally (with-simple-restart (continue "Return NIL instead.")
                        (error 'dns-servers-exhausted)))))))

(defun query-data (hostname &rest args &key type dns-servers attempts timeout)
  (declare (ignore dns-servers attempts timeout))
  (loop for record in (getf (apply #'query hostname args) :answers)
        when (eql type (getf record :type))
        collect (getf record :data)))

(defun resolve (hostname &rest args &key type dns-servers attempts timeout)
  (declare (ignore dns-servers attempts timeout))
  (handler-case
      (handler-bind ((dns-server-failure #'continue))
        (let ((list (if type
                        (apply #'query-data hostname args)
                        (append (apply #'query-data hostname :type :A args)
                                (apply #'query-data hostname :type :AAAA args)))))
          (values (first list) list T)))
    (dns-servers-exhausted ()
      (values NIL NIL NIL))))

(defun hostname (ip &rest args &key type dns-servers attempts timeout)
  (declare (ignore type dns-servers attempts timeout))
  (handler-case
      (handler-bind ((dns-server-failure #'continue))
        (let* ((ipv6-p (find #\: ip))
               (parts (if ipv6-p
                          (loop for byte across (usocket:ipv6-host-to-vector ip)
                                collect (format NIL "~x" (ldb (byte 4 4) byte))
                                collect (format NIL "~x" (ldb (byte 4 0) byte)))
                          (split #\. ip)))
               (list (apply #'query-data (format NIL "~{~a.~}~:[in-addr~;ip6~].arpa" (nreverse parts) ipv6-p) :type :PTR args)))
          (values (first list) list T)))
    (dns-condition ()
      (values NIL NIL NIL))))
