require 'spec_helper'

require 'tmpdir'
require 'openssl'

describe Bosh::Aws::ServerCertificate do
  let(:subject_name) { '/C=US/O=Pivotal/CN=myapp.foo.com' }
  let(:dns_record) { 'myapp' }
  let(:domain) { 'foo.com' }
  let(:server_certificate) { described_class.new(key_path, certificate_path, domain, dns_record) }

  describe '#load_or_create' do
    context 'when the paths given do not exist' do
      let(:key_path) { File.join(Dir.tmpdir, 'ca.key') }
      let(:certificate_path) { File.join(Dir.tmpdir, 'ca.pem') }

      before do
        FileUtils.rm_f(key_path)
        FileUtils.rm_f(certificate_path)
      end

      it 'returns self so that it can be appended on to the constructor easily' do
        server_certificate.load_or_create.should == server_certificate
      end

      it 'creates a new, valid certificate' do
        server_certificate.load_or_create

        key = OpenSSL::PKey::RSA.new(File.read(key_path))
        certificate = OpenSSL::X509::Certificate.new(File.read(certificate_path))

        key.to_s.should include('BEGIN RSA PRIVATE KEY')
        certificate.to_s.should include('BEGIN CERTIFICATE')

        certificate.verify(key).should be_true
      end

      it 'sets the subject from the domain we ask for' do
        server_certificate.load_or_create

        certificate = OpenSSL::X509::Certificate.new(File.read(certificate_path))
        certificate.subject.to_s.should == subject_name
      end

      it 'has a sensible certificate lifetime' do
        server_certificate.load_or_create

        certificate = OpenSSL::X509::Certificate.new(File.read(certificate_path))
        start_time = certificate.not_before
        end_time = certificate.not_after

        (end_time - start_time).should == 3 * 365 * 24 * 60 * 60 # 3 Years
      end
    end

    context 'when the paths given do exist' do
      let(:key_path) { asset('ca/ca.key') }
      let(:certificate_path) { asset('ca/ca.pem') }
      let(:domain) { 'dev102.cf.com' }

      it 'loads the key and certificate from the files' do
        key_contents_before = File.read(key_path)
        certificate_contents_before = File.read(certificate_path)

        server_certificate.load_or_create

        server_certificate.key.should == key_contents_before
        server_certificate.certificate.should == certificate_contents_before
      end

      it 'does not write to the file unnecessarily' do
        File.should_not_receive(:write).with(any_args)
        server_certificate.load_or_create
      end

      it 'returns self so that it can be appended on to the constructor easily' do
        server_certificate.load_or_create.should == server_certificate
      end

      context 'when the user has a certificate chain' do
        let(:chain_path) { asset('ca/chain.pem') }
        let(:server_certificate) { described_class.new(key_path, certificate_path, domain, dns_record, chain_path) }

        it 'allows the user to read the contents of the chain file' do
          server_certificate.load_or_create

          server_certificate.chain.should include "BEGIN CERTIFICATE"
        end
      end

      context 'when the user does not have a certificate chain' do
        let(:server_certificate) { described_class.new(key_path, certificate_path, domain, dns_record) }

        it 'the certificate chain should be nil' do
          server_certificate.load_or_create

          server_certificate.chain.should be_nil
        end
      end

      describe 'verifying that the subject of the certificate we load matches the one was ask for' do
        context 'when it does match' do
          let(:domain) { 'dev102.cf.com' }

          it 'does not raise an exception' do
            expect {
              server_certificate.load_or_create
            }.to_not raise_error(Bosh::Aws::ServerCertificate::SubjectsDoNotMatchException)
          end
        end

        context 'when it does not match' do
          let(:domain) { 'bar.com' }

          it 'raises an exception' do
            expect {
              server_certificate.load_or_create
            }.to raise_error(Bosh::Aws::ServerCertificate::SubjectsDoNotMatchException,
              "The subject you provided is '/C=US/O=Pivotal/CN=myapp.bar.com' but the certificate you loaded has a subject of '/C=US/O=Pivotal/CN=myapp.dev102.cf.com'."
            )
          end
        end
      end
    end
  end
end
