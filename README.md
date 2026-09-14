## Setup — SDK nativo da Macrotellect

O app depende do `MacrotellectLink_V1.4.3.jar` (SDK proprietário da Macrotellect
para o headset EEG "BrainLink"). Esse arquivo **não está versionado** neste
repositório — baixe-o em:

https://github.com/Macrotellect/BrainLinkPro_Android

e coloque o `.jar` em `android/app/libs/` antes de compilar o app Android.

**Importante:** este app foi desenvolvido e testado exclusivamente para
**Android**, com a versão exata `MacrotellectLink_V1.4.3.jar`. O repositório
acima pode conter `.jar`s de outras versões/modelos do SDK — eles não são
garantidamente compatíveis e podem se comportar de forma diferente (ou nem
funcionar) com o código deste projeto.

Mais detalhes sobre o funcionamento do app e do protocolo em
[docs/FUNCIONAMENTO.md](docs/FUNCIONAMENTO.md).

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
