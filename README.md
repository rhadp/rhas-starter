# rhas-starter

A starter project for building RHIVOS/AutoSD images with sample automotive applications.

## Overview

This repo walks you through the developer workflow for automotive software: build your app locally or in a Cloud-based Development Environment (CDE), 
test it in a container, then deploy it to a virtual (or real) device. You'll use the same tools and patterns that work at scale in production.




oc apply -f manifests/app-qemu-exporter.yml -n openshift-gitops
oc delete app app-jumpstarter-qemu -n openshift-gitops