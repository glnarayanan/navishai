namespace :navishai do
  namespace :first_owner do
    desc "Exit 0 only while a fresh first-Owner bootstrap token may still be issued"
    task renewable: :environment do
      abort "first-Owner setup is already complete; the bootstrap token cannot be renewed" unless FirstOwnerBootstrap.renewable?
      puts "first-Owner bootstrap token may be renewed"
    end
  end
end
