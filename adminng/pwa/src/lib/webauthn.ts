/** Convert WebAuthn's JSON-safe base64url options to and from browser values. */

type JsonCredentialDescriptor = {
  id: string
  type: 'public-key'
  transports?: AuthenticatorTransport[]
}

export type RegistrationOptionsJSON = Omit<
  PublicKeyCredentialCreationOptions,
  'challenge' | 'user' | 'excludeCredentials'
> & {
  challenge: string
  user: Omit<PublicKeyCredentialUserEntity, 'id'> & { id: string }
  excludeCredentials?: JsonCredentialDescriptor[]
}

export type AuthenticationOptionsJSON = Omit<
  PublicKeyCredentialRequestOptions,
  'challenge' | 'allowCredentials'
> & {
  challenge: string
  allowCredentials?: JsonCredentialDescriptor[]
}

export type SerializedCredential = {
  id: string
  rawId: string
  type: 'public-key'
  response: Record<string, string | string[] | null>
  clientExtensionResults: AuthenticationExtensionsClientOutputs
  authenticatorAttachment: string | null
}

function fromBase64Url(value: string): ArrayBuffer {
  const base64 = value.replace(/-/g, '+').replace(/_/g, '/')
  const binary = atob(base64.padEnd(Math.ceil(base64.length / 4) * 4, '='))
  const bytes = new Uint8Array(binary.length)
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index)
  return bytes.buffer
}

function toBase64Url(value: ArrayBuffer): string {
  const bytes = new Uint8Array(value)
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '')
}

function requireWebAuthn(): void {
  if (!window.isSecureContext || !navigator.credentials) {
    throw new Error('WebAuthn requires a secure browser context')
  }
}

export async function createPlatformCredential(
  options: RegistrationOptionsJSON,
): Promise<SerializedCredential> {
  requireWebAuthn()
  const credential = await navigator.credentials.create({
    publicKey: {
      ...options,
      challenge: fromBase64Url(options.challenge),
      user: { ...options.user, id: fromBase64Url(options.user.id) },
      excludeCredentials: options.excludeCredentials?.map((item) => ({
        ...item,
        id: fromBase64Url(item.id),
      })),
    },
  })
  if (!(credential instanceof PublicKeyCredential)) {
    throw new Error('The platform authenticator did not return a credential')
  }

  const response = credential.response
  if (!(response instanceof AuthenticatorAttestationResponse)) {
    throw new Error('The platform authenticator returned an invalid registration response')
  }
  return {
    id: credential.id,
    rawId: toBase64Url(credential.rawId),
    type: 'public-key',
    response: {
      clientDataJSON: toBase64Url(response.clientDataJSON),
      attestationObject: toBase64Url(response.attestationObject),
      transports: response.getTransports(),
    },
    clientExtensionResults: credential.getClientExtensionResults(),
    authenticatorAttachment: credential.authenticatorAttachment,
  }
}

export async function getPlatformCredential(
  options: AuthenticationOptionsJSON,
): Promise<SerializedCredential> {
  requireWebAuthn()
  const credential = await navigator.credentials.get({
    publicKey: {
      ...options,
      challenge: fromBase64Url(options.challenge),
      allowCredentials: options.allowCredentials?.map((item) => ({
        ...item,
        id: fromBase64Url(item.id),
      })),
    },
  })
  if (!(credential instanceof PublicKeyCredential)) {
    throw new Error('The platform authenticator did not return a credential')
  }

  const response = credential.response
  if (!(response instanceof AuthenticatorAssertionResponse)) {
    throw new Error('The platform authenticator returned an invalid assertion response')
  }
  return {
    id: credential.id,
    rawId: toBase64Url(credential.rawId),
    type: 'public-key',
    response: {
      clientDataJSON: toBase64Url(response.clientDataJSON),
      authenticatorData: toBase64Url(response.authenticatorData),
      signature: toBase64Url(response.signature),
      userHandle: response.userHandle ? toBase64Url(response.userHandle) : null,
    },
    clientExtensionResults: credential.getClientExtensionResults(),
    authenticatorAttachment: credential.authenticatorAttachment,
  }
}
