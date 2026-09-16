# WAF Evidence — Allowed vs. Deterministic Blocked Request

Captured against the live App VM's public IP (redacted below as <APP_PUBLIC_IP>).

## Allowed request

    PS> curl.exe -k -o NUL -w "allowed -> %{http_code}`n" https://<APP_PUBLIC_IP>/
    allowed -> 200

## Deterministic blocked request (SQLi pattern)

    PS> curl.exe -k -o NUL -w "blocked -> %{http_code}`n" "https://<APP_PUBLIC_IP>/?id=1%27%20OR%201%3D1%20--%20"
    blocked -> 403

## Underlying Caddy access log entries (from /var/log/caddy/access.log on the App VM)

Allowed:

    {"level":"info","logger":"http.log.access.log0","msg":"handled request",
     "request":{"remote_ip":"<REDACTED>","method":"GET","host":"<APP_PUBLIC_IP>","uri":"/", ...},
     "status":200,"size":9393}

Blocked:

    {"level":"info","logger":"http.log.access.log0","msg":"handled request",
     "request":{"remote_ip":"<REDACTED>","method":"GET","host":"<APP_PUBLIC_IP>",
     "uri":"/?id=1%27%20OR%201%3D1%20--%20", ...},
     "status":403,"size":0}

Blocking is enforced by the Coraza WAF rule in scripts/app-userdata.sh.tpl:

    SecRule ARGS "@rx (?i:union(\s|\+)+select|or\s+1\s*=\s*1|or\s+'1'\s*=\s*'1|--\s|;--|<script|onerror\s*=)" \
      "id:1000,phase:2,deny,status:403,log,msg:'Blocked: SQLi/XSS pattern in request'"

Direct-origin bypass is structurally prevented: Juice Shop's Kubernetes Service is
ClusterIP (see k8s/juice-shop.yaml) — there is no NodePort or LoadBalancer path that
skips Caddy.
