# Wazuh Evidence — Fresh Event via the Verifier

Captured from a live run of `scripts/verify.py` against the deployed lab (also reproduced
automatically by `terraform/verify.tf`'s deployment gate on every `terraform apply`).

    root@app-vm:~# sudo python3 /tmp/verify.py \
        --app-url https://localhost/ \
        --indexer-url https://<WAZUH_PRIVATE_IP>:9200 \
        --indexer-user admin --indexer-pass <REDACTED> \
        --readiness-timeout 60 --delivery-timeout 60

    [READY] Juice Shop / WAF
    [READY] Wazuh Indexer
    [INFO] Sending marker request: https://localhost/?verify=verifier-e7233feae87746e0b4147cc1eabe3521
    [INFO] Marker request returned status 200
    [READY] marker 'verifier-e7233feae87746e0b4147cc1eabe3521' indexed in Wazuh
    [SUCCESS] Marker 'verifier-e7233feae87746e0b4147cc1eabe3521' confirmed in Wazuh Indexer. Full pipeline verified end-to-end.
    EXIT CODE: 0

## Direct Indexer query confirming the same event (run on the Wazuh VM)

Authenticated against the Indexer's REST API (basic auth, credentials redacted) and
filtered to alerts matched by our custom rule 100010:

    root@wazuh-vm:~# QUERY_URL="https://localhost:9200/wazuh-alerts-*/_search?q=rule.id:100010&pretty"
    root@wazuh-vm:~# curl -sk --user "<REDACTED>" "$QUERY_URL" | grep -A5 "verify=phase4livetest"

                "uri" : "/?verify=phase4livetest"
              },
              ...
            "rule" : {
              "id" : "100010"
            },
            "decoder" : {
              "name" : "json"
            },
            "location" : "/var/log/caddy/access.log",

This confirms the full pipeline: a request through the WAF -> Caddy's JSON access log ->
Wazuh agent on the App VM -> Wazuh manager custom rule 100010 (wazuh/caddy_rules.xml) ->
indexed into wazuh-alerts-* on the Wazuh Indexer, queryable via its REST API.

Index confirmed populated:

    root@wazuh-vm:~# curl -sk --user "<REDACTED>" "https://localhost:9200/_cat/indices/wazuh-alerts-*?v"
    health status index                       ... docs.count ...
    green  open   wazuh-alerts-4.x.<date>     ...    398      ...
