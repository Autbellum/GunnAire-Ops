import base64
import json
import unittest
from datetime import datetime,timezone
from unittest import mock
from cryptography.hazmat.primitives import hashes,serialization
from cryptography.hazmat.primitives.asymmetric import ec,utils
from Backend import gunnaire_backend as backend


class APNsEnvironmentKeyTests(unittest.TestCase):
    def setUp(self):
        self.production=ec.generate_private_key(ec.SECP256R1())
        self.sandbox=ec.generate_private_key(ec.SECP256R1())
        def encode(key):
            return base64.b64encode(key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption())).decode()
        self.settings=mock.patch.multiple(backend,APNS_TEAM_ID='ABCDEFGHIJ',APNS_TOPIC='com.example.fixture',
            APPLE_CLIENT_ID='com.example.fixture',APNS_KEY_ID='',APNS_PRIVATE_KEY_BASE64='',
            APNS_PRODUCTION_KEY_ID='PROD123456',APNS_PRODUCTION_PRIVATE_KEY_BASE64=encode(self.production),
            APNS_SANDBOX_KEY_ID='TEST123456',APNS_SANDBOX_PRIVATE_KEY_BASE64=encode(self.sandbox),APNS_AUTH_TOKEN_CACHE={})
        self.settings.start();self.addCleanup(self.settings.stop)

    def verify(self,token,key,identifier):
        header,claims,signature=token.split('.')
        decode=lambda value:base64.urlsafe_b64decode(value+'='*(-len(value)%4))
        self.assertEqual(json.loads(decode(header)),{'alg':'ES256','kid':identifier})
        self.assertEqual(json.loads(decode(claims))['iss'],'ABCDEFGHIJ')
        raw=decode(signature)
        der=utils.encode_dss_signature(int.from_bytes(raw[:32],'big'),int.from_bytes(raw[32:],'big'))
        key.public_key().verify(der,(header+'.'+claims).encode(),ec.ECDSA(hashes.SHA256()))

    def test_environment_specific_signatures_and_independent_caches(self):
        now=datetime(2026,11,8,tzinfo=timezone.utc)
        production=backend.apns_authentication_token(now,environment='production')
        sandbox=backend.apns_authentication_token(now,environment='development')
        self.verify(production,self.production,'PROD123456')
        self.verify(sandbox,self.sandbox,'TEST123456')
        self.assertEqual(backend.apns_authentication_token(now,environment='production'),production)
        self.assertEqual(backend.apns_authentication_token(now,environment='development'),sandbox)
        self.assertEqual(set(backend.APNS_AUTH_TOKEN_CACHE),{'production','development'})

    def test_legacy_fallback_only_for_wholly_unconfigured_environment(self):
        legacy=backend.APNS_PRODUCTION_PRIVATE_KEY_BASE64
        with mock.patch.multiple(backend,APNS_SANDBOX_KEY_ID='',APNS_SANDBOX_PRIVATE_KEY_BASE64='',
                                 APNS_KEY_ID='LEGACY1234',APNS_PRIVATE_KEY_BASE64=legacy):
            self.assertEqual(backend.apns_signing_configuration('development'),('LEGACY1234',legacy))
            with mock.patch.object(backend,'APNS_SANDBOX_KEY_ID','PARTIAL123'):
                with self.assertRaises(ValueError):backend.apns_signing_configuration('development')
                self.assertFalse(backend.apns_configuration_is_present())

    def test_http_host_and_signing_key_select_same_environment_without_provider_calls(self):
        response=mock.Mock(status_code=200,content=b'',headers={})
        with mock.patch('httpx.Client') as client:
            sender=client.return_value.__enter__.return_value
            sender.post.return_value=response
            for environment,host,key,key_id in [('production','api.push.apple.com',self.production,'PROD123456'),
                                               ('development','api.sandbox.push.apple.com',self.sandbox,'TEST123456')]:
                self.assertEqual(backend.send_apns_request(device_token='a'*64,environment=environment,payload={},collapse_id='fixture')[0],200)
                args,kwargs=sender.post.call_args
                self.assertTrue(args[0].startswith('https://'+host+'/3/device/'))
                self.verify(kwargs['headers']['authorization'].removeprefix('bearer '),key,key_id)
            calls=sender.post.call_count
            with self.assertRaises(ValueError):backend.send_apns_request(device_token='a'*64,environment='invalid',payload={},collapse_id='fixture')
            self.assertEqual(sender.post.call_count,calls)

if __name__=='__main__':unittest.main()
