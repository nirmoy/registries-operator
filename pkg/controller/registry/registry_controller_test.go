/*
 * Copyright 2018 SUSE LINUX GmbH, Nuernberg, Germany..
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 */

package registry

import (
	"testing"
	"time"

	"github.com/onsi/gomega"
	"golang.org/x/net/context"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	kubicv1beta1 "github.com/kubic-project/registries-operator/pkg/apis/kubic/v1beta1"
	"github.com/kubic-project/registries-operator/pkg/test"
)

var c client.Client

var expectedRequest = reconcile.Request{NamespacedName: types.NamespacedName{Name: "foo", Namespace: ""}}

//TODO: reuse logic for naming from registry_cert_instaler.go to avoid hardcoding
var jobKey = types.NamespacedName{Name: "kubic-registry-installer-foo.com:5000", Namespace: metav1.NamespaceSystem}

const timeout = time.Second * 5

func TestReconcile(t *testing.T) {

	test.SkipUnlessIntegrationTesting(t)

	g := gomega.NewGomegaWithT(t)
	instance := &kubicv1beta1.Registry{ObjectMeta: metav1.ObjectMeta{Name: "foo", Namespace: ""}, Spec: kubicv1beta1.RegistrySpec{HostPort: "foo.com:5000", Certificate: &corev1.SecretReference{Name: "foo"}}}

	// Setup the Manager and Controller.  Wrap the Controller Reconcile function so it writes each request to a
	// channel when it is finished.
	mgr, err := manager.New(cfg, manager.Options{})
	g.Expect(err).NotTo(gomega.HaveOccurred())
	c = mgr.GetClient()

	recFn, requests := SetupTestReconcile(newRegistryReconcilier(mgr))
	g.Expect(addRegController(mgr, recFn)).NotTo(gomega.HaveOccurred())
	defer close(StartTestManager(mgr, g))

	// Create the Registry object and expect the Reconcile and Deployment to be created
	err = c.Create(context.TODO(), instance)
	// The instance object may not be a valid object because it might be missing some required fields.
	// Please modify the instance object by adding required fields and then remove the following if statement.
	if apierrors.IsInvalid(err) {
		t.Logf("failed to create object, got an invalid object error: %v", err)
		return
	}
	g.Expect(err).NotTo(gomega.HaveOccurred())
	defer c.Delete(context.TODO(), instance)
	g.Eventually(requests, timeout).Should(gomega.Receive(gomega.Equal(expectedRequest)))

	job := &batchv1.Job{}
	g.Eventually(func() error { return c.Get(context.TODO(), jobKey, job) }, timeout).
		Should(gomega.Succeed())

	// Delete the Job and expect Reconcile to be called for Job deletion
	g.Expect(c.Delete(context.TODO(), job)).NotTo(gomega.HaveOccurred())
	g.Eventually(requests, timeout).Should(gomega.Receive(gomega.Equal(expectedRequest)))
	g.Eventually(func() error { return c.Get(context.TODO(), jobKey, job) }, timeout).
		Should(gomega.Succeed())

	// Manually delete job since GC isn't enabled in the test control plane
	g.Expect(c.Delete(context.TODO(), job)).To(gomega.Succeed())

}
