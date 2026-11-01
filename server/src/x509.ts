// Single entry point for @peculiar/x509. It depends on tsyringe, which needs the reflect-metadata
// polyfill loaded first; importing x509 only through this file guarantees that order.
import "reflect-metadata";
export { BasicConstraintsExtension, X509Certificate, X509CertificateGenerator } from "@peculiar/x509";
