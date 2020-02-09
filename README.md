# node-iptables-controller

Kubernetes daemonset used to apply firewall rules on each node in the cluster

## Getting Started

### Installing

* Configure your rules in a configmap named `iptables-rules` in the `kube-system` namespace. See `manifests/configmap.yaml` for example.
* Apply the daemonset:
  `kubectl apply -f manifests/iptables.yaml`

## Authors

* **Logan V.** - [logan2211](https://github.com/logan2211)

See also the list of [contributors](https://github.com/logan2211/node-iptables-controller/contributors) who participated in this project.

## License

 [Apache2](LICENSE)
