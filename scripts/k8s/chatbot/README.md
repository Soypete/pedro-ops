# chatbot k8s manifests

The Twitch auth ingress (`pedro-twitch-auth-ingress`) is **managed by the Helm chart** in
`iam_pedro/charts/pedro-bots/templates/twitch-auth-ingress.yaml`.

Do not apply a standalone ingress manifest here — it will conflict with Helm's managed resource.

To update the ingress, edit the Helm template and run:
```bash
helm upgrade pedro ./charts/pedro-bots --namespace chatbot --values /tmp/pedro-secrets.yaml
```
