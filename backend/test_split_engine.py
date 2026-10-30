import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import split_engine as s

class SplitTests(unittest.TestCase):
    def test_reject_reserved_overlap_and_probe(self):
        for cidr in ['0.0.0.0/0','100.0.0.0/8','192.0.0.0/8','198.0.0.0/8','224.0.0.0/4','1.1.1.0/24']:
            with self.subTest(cidr=cidr),self.assertRaises(ValueError):
                s.validate_config({'extra_direct':[cidr]})

    def test_sync_ownership(self):
        with tempfile.TemporaryDirectory() as d, patch.object(s,'BASE',Path(d)),patch.object(s,'publish'):
            path=s.BASE/'owned-routes.json'
            def fake(*args): return SimpleNamespace(returncode=0,stdout='1',stderr='')
            existing={'8.8.8.0/24':{'gateway':'192.168.2.1','interface':'en0','flags':'UGS'}}
            with patch.object(s,'route_snapshot',return_value=existing),patch.object(s,'command',side_effect=fake) as command:
                s.sync(dict(s.DEFAULT,mode='split'),['8.8.8.0/24','9.9.9.0/24'],'utun4')
                self.assertEqual(json.loads(path.read_text()),{'9.9.9.0/24':'192.168.2.1'})
                adds=[x.args for x in command.call_args_list if 'add' in x.args]
                self.assertEqual(len(adds),1)
            # Someone else changed our route; full mode must leave it alone.
            altered={'9.9.9.0/24':{'gateway':'192.168.2.88','interface':'en0','flags':'UGS'}}
            with patch.object(s,'route_snapshot',return_value=altered),patch.object(s,'command',side_effect=fake) as command:
                s.sync(dict(s.DEFAULT,mode='full'),[],'')
                self.assertEqual(json.loads(path.read_text()),{})
                self.assertFalse(any('delete' in x.args for x in command.call_args_list))

    def test_gateway_change(self):
        with tempfile.TemporaryDirectory() as d,patch.object(s,'BASE',Path(d)),patch.object(s,'publish'):
            (s.BASE/'owned-routes.json').write_text(json.dumps({'9.9.9.0/24':'192.168.2.1'}))
            old={'9.9.9.0/24':{'gateway':'192.168.2.1','interface':'en0','flags':'UGS'}}
            with patch.object(s,'route_snapshot',return_value=old),patch.object(s,'command',return_value=SimpleNamespace(returncode=0,stdout='1',stderr='')) as c:
                s.sync(dict(s.DEFAULT,mode='split',gateway='192.168.2.88'),['9.9.9.0/24'],'utun4')
                self.assertTrue(any('delete' in x.args for x in c.call_args_list))
                self.assertTrue(any('add' in x.args for x in c.call_args_list))

    def test_full_cleanup_before_tailscale_ready(self):
        spec=importlib.util.spec_from_file_location('watch',Path(__file__).with_name('tailscale-gateway-watch.py'))
        w=importlib.util.module_from_spec(spec);spec.loader.exec_module(w)
        with tempfile.TemporaryDirectory() as d,patch.object(w,'BASE',Path(d)),patch.object(w,'status'),patch.object(w,'run',return_value=''),patch.object(w,'split',s):
            with patch.object(s,'prepare',return_value=(dict(s.DEFAULT,mode='full'),[])),patch.object(s,'sync') as sync:
                w.main();sync.assert_called_once()

if __name__=='__main__': unittest.main()
