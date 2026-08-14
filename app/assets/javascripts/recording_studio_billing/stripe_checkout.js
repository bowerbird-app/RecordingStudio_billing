(() => {
  const mountEmbeddedCheckout = () => {
    document.querySelectorAll("[data-stripe-checkout-client-secret]").forEach((mount) => {
      if (!window.Stripe || mount.dataset.stripeCheckoutMounted) return;

      // The server supplies only a provider-created client secret. Card data is
      // submitted directly to Stripe and browser completion never fulfils an intent.
      mount.dataset.stripeCheckoutMounted = "true";
      const stripe = window.Stripe(mount.dataset.stripePublishableKey);
      stripe.initEmbeddedCheckout({ clientSecret: mount.dataset.stripeCheckoutClientSecret })
        .then((checkout) => checkout.mount(mount))
        .catch(() => {
          mount.removeAttribute("data-stripe-checkout-mounted");
          mount.parentElement.querySelector("[data-stripe-checkout-failure]").hidden = false;
        });
    });
  };

  document.addEventListener("turbo:load", mountEmbeddedCheckout);
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", mountEmbeddedCheckout, { once: true });
  } else {
    mountEmbeddedCheckout();
  }
})();