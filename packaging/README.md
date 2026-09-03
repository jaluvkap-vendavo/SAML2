# Vendavo packages from this fork

`Vendavo.SAML2.Core` and `Vendavo.Owin.Security.Saml` are built from
[this fork](https://github.com/jaluvkap-vendavo/SAML2) of
[elerch/SAML2](https://github.com/elerch/SAML2), which is licensed under the
**Mozilla Public License 2.0**. The modifications are described in
`CHANGELOG-VENDAVO.md`, shipped inside the packages; the complete corresponding source is
the fork repository itself.

## Use both, or neither

`Vendavo.Owin.Security.Saml` depends on `Vendavo.SAML2.Core`. Mixing one of these packages
with the public counterpart puts two assemblies with the identical identity
`SAML2.Core, Version=1.0.0.0` into the restore graph, and the build silently picks one.

## Assembly identity

`AssemblyVersion` is frozen at `1.0.0.0`, matching the published upstream 1.0.0 packages,
because consumers have no binding redirect for these assemblies. That also makes the
assemblies drop-in replacements in an existing deployment. The build is identified by
`AssemblyFileVersion` 1.0.1.0 and `AssemblyInformationalVersion` 1.0.1-vendavo.

## Rebuilding

    powershell -File packaging/pack.ps1

Requires VS 2022 MSBuild, the .NET Framework 4.8 targeting pack and a NuGet client 5.0 or
newer. See the header of `pack.ps1` for the two prerequisites that are not obvious: the
gitignored `*.Designer.cs` resource classes, and the dev certificates upstream never
committed.
