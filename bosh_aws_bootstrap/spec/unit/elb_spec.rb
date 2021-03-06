require 'spec_helper'

describe Bosh::Aws::ELB do
  let(:creds) { {'my' => 'creds'} }
  let(:elb) { described_class.new(creds) }
  let(:ec2) { Bosh::Aws::EC2.new({}) }
  let(:fake_aws_security_group) { mock('security_group', id: 'sg_id', name: 'security_group_name') }
  let(:fake_aws_vpc) { mock('vpc', security_groups: [fake_aws_security_group]) }
  let(:vpc) { Bosh::Aws::VPC.new(ec2, fake_aws_vpc) }
  let(:fake_aws_elb) { double(AWS::ELB, load_balancers: double()) }
  let(:certificates) { [] }
  let(:fake_aws_iam) { double(AWS::IAM, server_certificates: certificates) }

  it 'creates an underlying AWS ELB object with your credentials' do
    AWS::ELB.should_receive(:new).with(creds).and_call_original
    elb.send(:aws_elb).should be_kind_of(AWS::ELB)
  end

  describe 'creation' do
    let(:new_elb) { mock('a new elb') }
    let(:cert) { { 'certificate' => asset('ca/ca.pem'), 'private_key' => asset('ca/ca.key'), 'certificate_chain' => asset('ca/chain.pem') } }
    let(:cert_name) { 'my-cert-name' }
    let(:http_listener) { { port: 80, protocol: :http, instance_port: 80, instance_protocol: :http } }
    let(:https_listener) { { port: 443, protocol: :https, instance_port: 80, instance_protocol: :http, ssl_certificate_id: 'certificate_arn' } }
    let(:certs) { {} }

    before do
      elb.stub(:aws_elb).and_return(fake_aws_elb)
      new_elb.should_receive(:configure_health_check).with({
                                                               :healthy_threshold => 5,
                                                               :unhealthy_threshold => 2,
                                                               :interval => 5,
                                                               :timeout => 2,
                                                               :target => 'TCP:80'
                                                           })
      vpc.stub(:subnets).and_return({'sub_name1' => 'sub_id1', 'sub_name2' => 'sub_id2'})
      vpc.stub(:security_group_by_name).with('security_group_name').and_return(fake_aws_security_group)
    end

    it 'can create an ELB given a name and a vpc and a CIDR block' do
      fake_aws_elb.load_balancers.should_receive(:create).with('my elb name', {
          :listeners => [http_listener],
          :subnets => %w[sub_id1 sub_id2],
          :security_groups => %w[sg_id]
      }).and_return(new_elb)
      elb.create('my elb name', vpc, {'subnets' => %w(sub_name1 sub_name2), 'security_group' => 'security_group_name'}, certs).should == new_elb
    end

    describe 'creating a new ELB that allows HTTPS' do
      let(:certs) { {cert_name => cert} }
      let(:certificate) { double(AWS::IAM::ServerCertificate, arn: 'certificate_arn') }
      let(:certificates) { double(AWS::IAM::ServerCertificateCollection) }

      before do
        elb.stub(:aws_iam).and_return(fake_aws_iam)

        fake_aws_elb.load_balancers.should_receive(:create).with('my elb name', {
            listeners: [http_listener, https_listener],
            subnets: ['sub_id1', 'sub_id2'],
            security_groups: ['sg_id'],
        }).and_return(new_elb)
      end

      context 'if the certificate is self signed (has no certificate chain)' do
        let(:cert) { { 'certificate' =>  asset('ca/ca.pem'), 'private_key' => asset('ca/ca.key') } }

        before do
          certificates.should_receive(:upload).with(anything) do |args|
            args[:certificate_body].should match /BEGIN CERTIFICATE/
            args[:private_key].should match /BEGIN RSA PRIVATE KEY/
            args[:name].should == cert_name
            args.should_not have_key :certificate_chain
          end.and_return(certificate)
        end

        it 'can create a new ELB that is configured to allow HTTPS' do
          elb.create('my elb name', vpc, {'subnets' => %w(sub_name1 sub_name2),
                                          'security_group' => 'security_group_name',
                                          'https' => true,
                                          'ssl_cert' => cert_name,
                                          'dns_record' => 'myapp',
                                          'domain' => 'dev102.cf.com'}, certs).should == new_elb
        end
      end

      context 'if the certificate comes from a signing authority (has a certificate chain)' do
        before do
          certificates.should_receive(:upload).with(anything) do |args|
            args[:certificate_chain].should match /BEGIN CERTIFICATE/
            args[:certificate_body].should match /BEGIN CERTIFICATE/
            args[:private_key].should match /BEGIN RSA PRIVATE KEY/
            args[:name].should == cert_name
          end.and_return(certificate)
        end

        it 'can create a new ELB that is configured to allow HTTPS' do
          elb.create('my elb name', vpc, {'subnets' => %w(sub_name1 sub_name2),
                                          'security_group' => 'security_group_name',
                                          'https' => true,
                                          'ssl_cert' => cert_name,
                                          'dns_record' => 'myapp',
                                          'domain' => 'dev102.cf.com'}, certs).should == new_elb
        end
      end
    end
  end

  describe 'deletion' do
    let(:load_balancers) { [] }
    let(:server_certificates) { [] }

    before do
      elb.stub(:aws_elb).and_return(fake_aws_elb)
      elb.stub(:aws_iam).and_return(fake_aws_iam)

      fake_aws_iam.should_receive(:server_certificates).and_return(server_certificates)
      fake_aws_elb.should_receive(:load_balancers).and_return(load_balancers)
    end

    describe 'deleting each load balancer' do
      let(:elb1) { mock('elb1') }
      let(:elb2) { mock('elb2') }
      let(:load_balancers) { [elb1, elb2] }

      it 'should call delete on each ELB' do
        elb1.should_receive(:delete)
        elb2.should_receive(:delete)

        elb.delete_elbs
      end
    end

    describe 'deleting the server certificates' do
      let(:cert1) { mock('cert1') }
      let(:cert2) { mock('cert2') }
      let(:server_certificates) { [cert1, cert2] }

      it 'deletes all of the uploaded server certificates' do
        cert1.should_receive(:delete)
        cert2.should_receive(:delete)

        elb.delete_elbs
      end
    end
  end

  describe 'names' do
    before do
      elb.stub(:aws_elb).and_return(fake_aws_elb)
    end

    it 'returns the names of the running ELBs' do
      elb1 = mock('elb1', name: 'one')
      elb2 = mock('elb2', name: 'two')
      fake_aws_elb.should_receive(:load_balancers).and_return([elb1, elb2])
      elb.names.should == %w[one two]
    end
  end
end
