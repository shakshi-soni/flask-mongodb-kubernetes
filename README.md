# Flask + MongoDB on Kubernetes

A small Flask app that stores data in MongoDB, deployed on a local Kubernetes cluster (Minikube). The app has two routes, and `/data` handles both POST and GET:

- `GET /` shows a welcome message with the current time.
- `POST /data` saves a JSON document in MongoDB.
- `GET /data` returns all saved documents.

The goal of this project is to show how to run the app on Kubernetes with multiple replicas, a password-protected database, persistent storage, autoscaling, and resource limits.

## Architecture

```
Your machine
   |  minikube service flask-service --url
   v
flask-service (NodePort 30007 -> 5000)
   |
Flask Deployment (2 replicas, HPA scales 2 to 5 at 70% CPU)
   |  MONGODB_URI = mongodb://user:pass@mongodb-service:27017/?authSource=admin
   v  (Kubernetes DNS resolves "mongodb-service")
mongodb-service (headless, internal only)
   |
MongoDB StatefulSet (1 replica, authentication on)
   |  mounted at /data/db
   v
mongo-pvc --> mongo-pv (hostPath, 1Gi)
```

## Project structure

```
flask-mongodb-kubernetes/
├── app.py
├── requirements.txt
├── .gitignore
├── Dockerfile
├── README.md
└── k8s/
    ├── config-secret.yaml
    ├── pv-pvc.yaml
    ├── mongodb-statefulset.yaml
    ├── mongodb-service.yaml
    ├── flask-deployment.yaml
    ├── flask-service.yaml
    └── hpa.yaml
```

## What I used

- Python 3.11, Flask 3.0.3, pymongo 4.8.0, gunicorn 22.0.0
- Docker Desktop
- Minikube (Docker driver) and kubectl
- MongoDB 6.0

I used newer library versions than the ones in the assignment sheet (Flask 2.0.2, pymongo 3.12.0). The old versions are known to clash with newer Python versions and newer MongoDB servers. The app code works the same on both.

## Part 1 note: virtual environments

Part 1 was local preparation and did not need to be submitted, so everything below is Part 2. The sheet does ask why a virtual environment is useful, so here is my answer:

- Each project gets its own packages, so one project's versions do not break another's.
- It keeps the system Python clean.
- `requirements.txt` plus a virtual environment makes the setup easy to repeat on any machine.

## Part 2: Kubernetes deployment

### 1. Install and set up Minikube

Docker Desktop must be installed and running first.

Windows (PowerShell):
```
winget install Kubernetes.minikube
winget install Kubernetes.kubectl
```

Mac:
```
brew install minikube kubectl
```

Close and reopen the terminal after installing, then check:
```
docker --version
minikube version
kubectl version --client
```

Start the cluster and turn on the metrics server. The HPA needs it to read CPU usage:
```
minikube start --driver=docker
minikube addons enable metrics-server
```

### 2. Build the Docker image

From the project folder (where the `Dockerfile` is):
```
docker build -t shakshi18soni/flask-mongo-app:1.0 .
```

The Dockerfile uses `python:3.11-slim`, installs the packages from `requirements.txt`, copies `app.py`, and starts the app with Gunicorn on port 5000.

The only change I made to `app.py` is for authentication. It has no username or password in it. It reads the full connection string from the `MONGODB_URI` environment variable, and Kubernetes fills that in from a Secret.

### 3. Push the image to Docker Hub

```
docker login
docker push shakshi18soni/flask-mongo-app:1.0
```

The repository must be public, so the cluster can pull it without extra credentials. The image name here must match the `image:` line in `k8s/flask-deployment.yaml`.

Image on Docker Hub: https://hub.docker.com/r/shakshi18soni/flask-mongo-app

### 4. Deploy to Kubernetes

Apply the files in this order. The order matters because Flask needs the Secret and MongoDB to exist:

```
kubectl apply -f k8s/config-secret.yaml
kubectl apply -f k8s/pv-pvc.yaml
kubectl apply -f k8s/mongodb-service.yaml
kubectl apply -f k8s/mongodb-statefulset.yaml
kubectl apply -f k8s/flask-deployment.yaml
kubectl apply -f k8s/flask-service.yaml
kubectl apply -f k8s/hpa.yaml
```

Check that everything is running:
```
kubectl get pods,svc,pv,pvc,hpa
```

You should see `mongodb-0` and two `flask-app` pods as `1/1 Running`, and the PVC as `Bound`. This is what mine looked like:

![All resources running](https://github.com/user-attachments/assets/6ec51328-1381-4e29-8f7f-9297f15622cf)

### 5. Access the application

With the Docker driver on Windows, the NodePort is not directly reachable from the host. This command opens a tunnel and prints a local URL. Keep that terminal open:

```
minikube service flask-service --url
```

It prints something like `http://127.0.0.1:54321`. Use that URL below (PowerShell):

```
Invoke-RestMethod http://127.0.0.1:54321/

Invoke-RestMethod -Method Post -Uri http://127.0.0.1:54321/data -ContentType "application/json" -Body '{"sampleKey":"sampleValue"}'

Invoke-RestMethod http://127.0.0.1:54321/data
```

On Mac or Linux you can use curl:
```
curl http://127.0.0.1:54321/
curl -X POST -H "Content-Type: application/json" -d '{"sampleKey":"sampleValue"}' http://127.0.0.1:54321/data
curl http://127.0.0.1:54321/data
```

## What each Kubernetes file does

| File | What it creates |
|---|---|
| `config-secret.yaml` | A Secret with the MongoDB username and password |
| `pv-pvc.yaml` | A 1Gi PersistentVolume and a claim (PVC) that binds to it |
| `mongodb-statefulset.yaml` | MongoDB with authentication on, storing data on the PVC |
| `mongodb-service.yaml` | An internal-only service so Flask can reach MongoDB |
| `flask-deployment.yaml` | The Flask app with 2 replicas, resource settings and health checks |
| `flask-service.yaml` | A NodePort service so I can reach Flask from my machine |
| `hpa.yaml` | The autoscaler: 2 to 5 replicas at 70% CPU |

## How authentication works

The MongoDB container creates its admin user the first time it starts, using the `MONGO_INITDB_ROOT_USERNAME` and `MONGO_INITDB_ROOT_PASSWORD` values from the Secret. Because these are set, MongoDB turns authentication on.

I did not put the password in `app.py` or in the image. The Flask Deployment reads the username and password from the same Secret and builds the connection string:

```
mongodb://<user>:<password>@mongodb-service:27017/?authSource=admin
```

`app.py` reads this from the `MONGODB_URI` environment variable. `authSource=admin` is needed because the user is created in the `admin` database.

One thing to know: these variables only work on the first start, when the data folder is empty. If you change the password later, you have to delete the old data first.

## How DNS works inside the cluster

Pods get new IP addresses every time they restart, so Flask cannot rely on a fixed IP for MongoDB. Kubernetes solves this with a built-in DNS server (CoreDNS).

1. Every Service gets a DNS name, in the form `<service-name>.<namespace>.svc.cluster.local`. My MongoDB service is `mongodb-service` in the `default` namespace, so its full name is `mongodb-service.default.svc.cluster.local`.
2. Every pod is set up to use CoreDNS, and its search domains include the namespace. So from a pod in the same namespace, the short name `mongodb-service` is enough.
3. When Flask connects to `mongodb-service:27017`, the DNS server answers with the address of the MongoDB pod. If the pod restarts and gets a new IP, the name still works.

My MongoDB service is headless (`clusterIP: None`), so the DNS name returns the pod's IP directly. The StatefulSet pod also gets its own stable name: `mongodb-0.mongodb-service.default.svc.cluster.local`.

That is why the Flask connection string uses the service name and not an IP address.

## Resource requests and limits

Both Flask and MongoDB use the values from the assignment:

| | Request | Limit |
|---|---|---|
| CPU | 200m (0.2 CPU) | 500m (0.5 CPU) |
| Memory | 250Mi | 500Mi |

The sheet writes the memory values as 250M and 500M. I used `Mi`, which is the usual Kubernetes unit and is very close in size.

**Request** is the amount Kubernetes reserves for the container. The scheduler uses it to decide which node has enough room for the pod. It is a guarantee.

**Limit** is the maximum the container is allowed to use. If it goes over the CPU limit, it gets slowed down (throttled). If it goes over the memory limit, it gets killed (OOMKilled) and restarted.

Why this matters:
- One pod cannot eat all the resources and starve the others.
- The scheduler can place pods properly.
- The HPA needs a CPU request to work. It calculates utilization as a percentage of the request. With a 200m request, 70% means about 140m of CPU.

MongoDB uses a lot of memory by default for its cache, which can go past a 500Mi limit. So I start it with `--wiredTigerCacheSizeGB 0.25` to keep it inside the limit.

## Design choices

| Choice | Why I picked it | Alternative I considered |
|---|---|---|
| Minikube with Docker driver | Simple, standard, and works well on Windows | kind or k3s (also fine), Docker Desktop's built-in Kubernetes (no easy metrics-server setup) |
| StatefulSet for MongoDB | Gives a stable pod name and storage, which databases need | A normal Deployment (the pod name and storage can change) |
| Headless ClusterIP service for MongoDB | Internal only, and the correct pairing for a StatefulSet | A normal ClusterIP (also works, but headless suits a StatefulSet) |
| NodePort for Flask | Easy to reach from my machine on Minikube | LoadBalancer (needs `minikube tunnel`) or Ingress (more setup than this task needs) |
| hostPath PersistentVolume | Fine for a single-node local cluster | Cloud disks or a dynamic StorageClass (better for real clusters) |
| Secret for credentials | The password stays out of the code and the image | Hardcoding the password (unsafe), ConfigMap (not meant for secrets) |
| Gunicorn in the container | The Flask development server is not meant for running an app | `flask run` (simpler, but not production-ready) |
| `mongo:6.0` pinned | The same version every time | `mongo:latest` (can change and break things) |
| One MongoDB replica | Enough for this task and keeps it simple | A replica set (better for high availability, much more setup) |
| Readiness and liveness probes on Flask `/` | Traffic only goes to ready pods, and stuck pods get restarted | No probes (simpler, but less reliable) |

The Secret in this repo is plain YAML with a demo password. In a real project I would not commit it to Git. I would use something like Sealed Secrets or an external secrets manager.

## Testing

Everything below was run on my own Minikube cluster.

### A. Database operations

I tested all three endpoints through the tunnel URL.

1. `GET /` returned `Welcome to the Flask app! The current time is: 2026-11-13 05:32:41.276503`.
2. `POST /data` returned `Data inserted`.
3. `GET /data` returned `sampleKey: sampleValue`.

This also shows that Flask connects to the password-protected MongoDB through the service name.

![Endpoint tests](screenshots/endpoints.png)

### B. Data persistence

To check that the PV and PVC work, I deleted the MongoDB pod and checked that the data was still there:

```
kubectl delete pod mongodb-0
kubectl get pods -w
```

The new `mongodb-0` was `1/1 Running` about 11 seconds later. I called `GET /data` again and it still returned `sampleKey: sampleValue`, so the data survived the restart.

![After deleting the MongoDB pod](screenshots/persistence.png)

### C. Autoscaling under high traffic

First I confirmed the HPA could read CPU:
```
kubectl get hpa
```

Then I started load generator pods that send requests to the Flask service in a loop:

```
kubectl run load-generator-1 --image=busybox:1.36 --restart=Never -- /bin/sh -c "while true; do wget -q -O- http://flask-service:5000/ > /dev/null; done"
kubectl run load-generator-2 --image=busybox:1.36 --restart=Never -- /bin/sh -c "while true; do wget -q -O- http://flask-service:5000/ > /dev/null; done"
kubectl run load-generator-3 --image=busybox:1.36 --restart=Never -- /bin/sh -c "while true; do wget -q -O- http://flask-service:5000/ > /dev/null; done"
```

In another terminal I watched the autoscaler and the pods:

```
kubectl get hpa -w
kubectl get pods -w
```

Results:

- Before the load there were 2 replicas and CPU was about 1% (`1%/70%`).
- CPU went above 70% and the HPA scaled from 2 to 3 replicas. `kubectl describe hpa flask-hpa` shows a `SuccessfulRescale` event: "New size: 3; reason: cpu resource utilization (percentage of request) above target".
- With 3 replicas the average CPU settled between 54% and 59%. That is below the target, so it stayed at 3. I added two more load generators (5 in total) and it made no difference. **It never reached the maximum of 5 replicas.** My guess is that each load pod sends only one request at a time, so they cannot push CPU much higher. I did not confirm that.
- When I deleted the load pods, CPU dropped from about 48% to about 1%, and a few minutes later the replicas went back down to 2. Scale-down is slower on purpose, because Kubernetes waits before removing pods.

```
kubectl delete pod load-generator-1 load-generator-2 load-generator-3 load-generator-4 load-generator-5
```


### D. Other checks

**MongoDB authentication.** From inside the MongoDB pod I ran `mongosh` twice. With a wrong password it failed with `MongoServerError: Authentication failed.` With the correct password it returned `{ ok: 1 }`.

**Resource requests and limits.** I read them back with `kubectl get ... -o jsonpath`. Both MongoDB and Flask show requests of `200m` CPU and `250Mi` memory, and limits of `500m` CPU and `500Mi` memory.

**DNS.** I ran `nslookup mongodb-service` from a temporary busybox pod. It resolved `mongodb-service.default.svc.cluster.local` to `10.244.0.7`. The `NXDOMAIN` lines printed before that are normal. The pod tries the short name against each search domain first, and only the full service name matches.

**A Flask pod failing.** I deleted one Flask pod. Kubernetes created a replacement on its own right away. It showed `0/1` for a short while and then `1/1`, and the Deployment was back to 2 pods.

**Final state.** `kubectl get pods,svc,pv,pvc,hpa` showed 2 Flask pods and `mongodb-0` all `1/1 Running`, the PVC `Bound`, and the HPA at 2 replicas with CPU at 1%. That is the screenshot in step 4.

### Issues I ran into

- **Docker and kubectl "not recognized" in the terminal.** I had opened VS Code before installing the tools, so the terminal did not know the new paths. Closing and reopening VS Code fixed it. Minikube and kubectl also needed their own install.
- **Pods stuck on `ContainerCreating` for several minutes.** It took close to ten minutes in total. The events showed normal `Pulling image` messages with no errors. The MongoDB image is large and my connection was slow, so I think it just took time.
- **HPA showed `<unknown>/70%` at first.** The metrics server was still starting up. It started showing real numbers after a couple of minutes.
- **The app address kept changing.** The URL from `minikube service flask-service --url` gets a new port every time the tunnel restarts, and the terminal has to stay open. I had to copy the new port a few times. `kubectl port-forward svc/flask-service 5000:5000` would be steadier.
- **The autoscaler stopped at 3 replicas.** As described above, my load generators could not push CPU high enough to reach 5. I wrote down what really happened.
- **One `FailedGetScale ... Unauthorized` warning** appeared in the HPA events during the load test. Scaling kept working (`ScalingActive: True`), and I did not find the cause.

## Clean up

```
kubectl delete -f k8s/
minikube stop
```

To also delete the saved database data, run `minikube delete`.
